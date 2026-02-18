// ModelManager.swift — Downloads model archive from GitHub releases.
// Handles download, tar extraction, progress reporting, and
// on-disk model discovery. Used by AppState.ensureModel() on first launch.
// VAD (silero_vad.onnx) is bundled in the app by Bazel and not downloaded.

import Foundation

final class ModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Result<ModelPaths, Error>) -> Void
    private var session: URLSession?

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Result<ModelPaths, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    // MARK: - Model discovery

    /// Searches well-known locations for an already-downloaded model.
    static func findExisting() -> ModelPaths? {
        guard let modelDir = findModelDir() else { return nil }
        guard let vadPath = findVADPath() else { return nil }
        return ModelPaths(modelDir: modelDir, vadPath: vadPath)
    }

    private static func findModelDir() -> String? {
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/\(ModelVariant.checkFile)") {
            return envDir
        }

        let appSupport = appSupportModelsPath()
        let modelPath = "\(appSupport)/\(ModelVariant.modelDirName)"
        if FileManager.default.fileExists(atPath: modelPath + "/\(ModelVariant.checkFile)") {
            return modelPath
        }

        if let resourcePath = Bundle.main.resourcePath {
            let bundled = "\(resourcePath)/models/\(ModelVariant.modelDirName)"
            if FileManager.default.fileExists(atPath: bundled + "/\(ModelVariant.checkFile)") {
                return bundled
            }
        }

        return nil
    }

    /// VAD is bundled by Bazel into the app's resources.
    private static func findVADPath() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = "\(resourcePath)/silero_vad.onnx"
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        return nil
    }

    private static func appSupportModelsPath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path
        return "\(appSupport)/models"
    }

    static var installBase: String {
        appSupportModelsPath()
    }

    /// Cancels any in-flight download.
    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    /// Removes the downloaded model from disk.
    static func deleteModel() throws {
        let path = "\(appSupportModelsPath())/\(ModelVariant.modelDirName)"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Download

    /// Starts download of the model archive.
    func download() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let modelTask = session!.downloadTask(with: ModelVariant.downloadURL)
        modelTask.resume()
    }

    // MARK: - Delegate state

    private var downloadError: Error?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 0.9
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let installBase = Self.installBase
        do {
            try FileManager.default.createDirectory(atPath: installBase, withIntermediateDirectories: true)
        } catch {
            onComplete(.failure(error))
            return
        }

        // Model archive: extract tar.bz2
        onProgress(0.9)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", location.path, "-C", installBase]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                onComplete(.failure(ChirpError.extractionFailed))
                return
            }
        } catch {
            onComplete(.failure(error))
            return
        }

        let modelDir = "\(installBase)/\(ModelVariant.modelDirName)"
        guard FileManager.default.fileExists(atPath: modelDir + "/\(ModelVariant.checkFile)") else {
            onComplete(.failure(ChirpError.modelFilesNotFound))
            return
        }

        guard let vadPath = Self.findVADPath() else {
            onComplete(.failure(ChirpError.vadNotBundled))
            return
        }

        onProgress(1.0)
        onComplete(.success(ModelPaths(modelDir: modelDir, vadPath: vadPath)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                return
            }
            onComplete(.failure(error))
        }
    }

    enum ChirpError: LocalizedError {
        case extractionFailed
        case modelFilesNotFound
        case vadNotBundled

        var errorDescription: String? {
            switch self {
            case .extractionFailed: return "Failed to extract model archive"
            case .modelFilesNotFound: return "Model files not found after extraction"
            case .vadNotBundled: return "silero_vad.onnx not found in app bundle"
            }
        }
    }
}
