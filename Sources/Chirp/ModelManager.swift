import Foundation

final class ModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    static let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
    static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelName).tar.bz2")!

    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Result<String, Error>) -> Void
    private var downloadTask: URLSessionDownloadTask?

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    /// Returns the model directory if it already exists, nil otherwise.
    static func findExistingModel() -> String? {
        // Check environment variable first
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/encoder.int8.onnx") {
            return envDir
        }

        let candidates = modelSearchPaths()
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate + "/encoder.int8.onnx") {
                return candidate
            }
        }
        return nil
    }

    /// The directory where we'll store the downloaded model.
    static var modelInstallDir: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path
        return "\(appSupport)/models/\(modelName)"
    }

    private static func modelSearchPaths() -> [String] {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path

        let cwd = FileManager.default.currentDirectoryPath
        var paths = [
            "\(appSupport)/models/\(modelName)",
            "\(cwd)/models/\(modelName)",
            "\(cwd)/../models/\(modelName)",
            "\(cwd)/../../models/\(modelName)",
        ]

        if let resourcePath = Bundle.main.resourcePath {
            paths.append("\(resourcePath)/models/\(modelName)")
        }

        return paths
    }

    func download() {
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: Self.modelURL)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // Download is ~70% of the work, extraction is ~30%
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 0.7
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        onProgress(0.7)

        let installParent = (Self.modelInstallDir as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: installParent,
                withIntermediateDirectories: true
            )
        } catch {
            onComplete(.failure(error))
            return
        }

        // Extract tar.bz2 using /usr/bin/tar
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", location.path, "-C", installParent]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                onComplete(.failure(ChirpError.extractionFailed))
                return
            }

            onProgress(1.0)

            // Verify the model files exist
            let modelDir = Self.modelInstallDir
            guard FileManager.default.fileExists(atPath: modelDir + "/encoder.int8.onnx") else {
                onComplete(.failure(ChirpError.modelFilesNotFound))
                return
            }

            onComplete(.success(modelDir))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onComplete(.failure(error))
        }
    }

    enum ChirpError: LocalizedError {
        case extractionFailed
        case modelFilesNotFound

        var errorDescription: String? {
            switch self {
            case .extractionFailed: return "Failed to extract model archive"
            case .modelFilesNotFound: return "Model files not found after extraction"
            }
        }
    }
}
