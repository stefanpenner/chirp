// T5ModelManager.swift — Downloads T5-small ONNX model files from HuggingFace.
// Follows the existing ModelManager pattern: download, progress, discovery.
// Stores in ~/Library/Application Support/Chirp/models/t5-small-onnx/

import Foundation

final class T5ModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Result<String, Error>) -> Void  // Returns model dir path
    private var session: URLSession?
    private var pendingDownloads: Int = 0
    private var downloadErrors: [Error] = []
    private let lock = NSLock()

    static let modelDirName = "t5-small-onnx"

    /// Files to download from HuggingFace optimum/t5-small ONNX export.
    private static let files: [(name: String, url: String)] = [
        ("encoder_model.onnx", "https://huggingface.co/optimum/t5-small/resolve/main/encoder_model.onnx"),
        ("decoder_model.onnx", "https://huggingface.co/optimum/t5-small/resolve/main/decoder_model.onnx"),
        ("tokenizer.json", "https://huggingface.co/optimum/t5-small/resolve/main/tokenizer.json"),
    ]

    /// Check file to verify the model is complete.
    private static let checkFile = "encoder_model.onnx"

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    // MARK: - Model discovery

    /// Returns the model directory path if all files are present, nil otherwise.
    static func findExisting() -> String? {
        let modelDir = "\(installBase)/\(modelDirName)"
        guard FileManager.default.fileExists(atPath: "\(modelDir)/\(checkFile)"),
              FileManager.default.fileExists(atPath: "\(modelDir)/decoder_model.onnx"),
              FileManager.default.fileExists(atPath: "\(modelDir)/tokenizer.json") else {
            return nil
        }
        return modelDir
    }

    /// Whether the T5 model is downloaded and ready.
    static var isAvailable: Bool {
        findExisting() != nil
    }

    static var installBase: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path
        return "\(appSupport)/models"
    }

    /// Removes the downloaded T5 model from disk.
    static func deleteModel() throws {
        let path = "\(installBase)/\(modelDirName)"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// Cancels any in-flight downloads.
    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Download

    /// Starts downloading all model files.
    func download() {
        let modelDir = "\(Self.installBase)/\(Self.modelDirName)"
        do {
            try FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        } catch {
            onComplete(.failure(error))
            return
        }

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        lock.lock()
        pendingDownloads = Self.files.count
        downloadErrors.removeAll()
        lock.unlock()

        for file in Self.files {
            guard let url = URL(string: file.url) else { continue }
            let task = session!.downloadTask(with: url)
            task.taskDescription = file.name
            task.resume()
        }
    }

    // MARK: - Individual file sizes for weighted progress

    /// Approximate sizes for progress weighting (encoder ~141MB, decoder ~232MB, tokenizer ~2.4MB)
    private static let fileSizes: [String: Int64] = [
        "encoder_model.onnx": 141_000_000,
        "decoder_model.onnx": 232_000_000,
        "tokenizer.json": 2_400_000,
    ]
    private static let totalSize: Int64 = fileSizes.values.reduce(0, +)

    /// Per-file progress tracking
    private var fileProgress: [String: Double] = [:]

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let fileName = downloadTask.taskDescription else { return }
        let fileFraction = Double(Self.fileSizes[fileName] ?? 0) / Double(Self.totalSize)
        let fileProgress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        lock.lock()
        self.fileProgress[fileName] = fileProgress * fileFraction
        let totalProgress = self.fileProgress.values.reduce(0, +)
        lock.unlock()

        onProgress(min(totalProgress, 0.99))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let fileName = downloadTask.taskDescription else { return }
        let destPath = "\(Self.installBase)/\(Self.modelDirName)/\(fileName)"

        do {
            // Remove existing file if present (re-download)
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(atPath: destPath)
            }
            try FileManager.default.moveItem(atPath: location.path, toPath: destPath)
        } catch {
            lock.lock()
            downloadErrors.append(error)
            lock.unlock()
        }

        checkCompletion()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                return
            }
            lock.lock()
            downloadErrors.append(error)
            lock.unlock()
            checkCompletion()
        }
    }

    private func checkCompletion() {
        lock.lock()
        pendingDownloads -= 1
        let remaining = pendingDownloads
        let errors = downloadErrors
        lock.unlock()

        guard remaining <= 0 else { return }

        if let firstError = errors.first {
            onComplete(.failure(firstError))
            return
        }

        let modelDir = "\(Self.installBase)/\(Self.modelDirName)"
        guard FileManager.default.fileExists(atPath: "\(modelDir)/\(Self.checkFile)") else {
            onComplete(.failure(T5ModelError.filesNotFound))
            return
        }

        onProgress(1.0)
        onComplete(.success(modelDir))
    }

    enum T5ModelError: LocalizedError {
        case filesNotFound

        var errorDescription: String? {
            switch self {
            case .filesNotFound: return "T5 model files not found after download"
            }
        }
    }
}
