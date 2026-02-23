// SpeakerModelManager.swift — Downloads ECAPA-TDNN speaker embedding model from HuggingFace.
// Follows the T5ModelManager pattern: download, progress, discovery.
// Stores in ~/Library/Application Support/Chirp/models/ecapa-tdnn/

import Foundation

final class SpeakerModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Result<String, Error>) -> Void
    private var session: URLSession?
    private let lock = NSLock()

    static let modelDirName = "ecapa-tdnn"
    private static let fileName = "embedding_model.onnx"
    private static let downloadURL = "https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb/resolve/main/embedding_model.onnx"

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    // MARK: - Model discovery

    static func findExisting() -> String? {
        let modelPath = "\(installBase)/\(modelDirName)/\(fileName)"
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        return modelPath
    }

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

    static func deleteModel() throws {
        let path = "\(installBase)/\(modelDirName)"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Download

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

        guard let url = URL(string: Self.downloadURL) else {
            onComplete(.failure(SpeakerModelError.invalidURL))
            return
        }
        let task = session!.downloadTask(with: url)
        task.taskDescription = Self.fileName
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress(min(progress, 0.99))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destPath = "\(Self.installBase)/\(Self.modelDirName)/\(Self.fileName)"
        do {
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(atPath: destPath)
            }
            try FileManager.default.moveItem(atPath: location.path, toPath: destPath)
            onProgress(1.0)
            onComplete(.success(destPath))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                return
            }
            onComplete(.failure(error))
        }
    }

    enum SpeakerModelError: LocalizedError {
        case invalidURL
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid speaker model download URL"
            case .fileNotFound: return "Speaker model file not found after download"
            }
        }
    }
}
