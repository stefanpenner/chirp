// ModelManager.swift — Downloads model and VAD files from GitHub releases.
// Handles parallel download, tar extraction, progress reporting, and
// on-disk model discovery. Used by AppState.ensureModel() on first launch
// or when switching model variants.

import Foundation

final class ModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    static let vadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!

    private let variant: ModelVariant
    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Result<ModelPaths, Error>) -> Void
    private var session: URLSession?

    init(
        variant: ModelVariant,
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Result<ModelPaths, Error>) -> Void
    ) {
        self.variant = variant
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    // MARK: - Model discovery

    /// Searches well-known locations for an already-downloaded model.
    static func findExisting(variant: ModelVariant) -> ModelPaths? {
        guard let modelDir = findModelDir(variant: variant) else { return nil }
        guard let vadPath = findVADPath() else { return nil }
        return ModelPaths(modelDir: modelDir, vadPath: vadPath, variant: variant)
    }

    private static func findModelDir(variant: ModelVariant) -> String? {
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/\(variant.checkFile)") {
            return envDir
        }

        for path in searchPaths(suffix: "models/\(variant.modelDirName)") {
            if FileManager.default.fileExists(atPath: path + "/\(variant.checkFile)") {
                return path
            }
        }
        return nil
    }

    private static func findVADPath() -> String? {
        for path in searchPaths(suffix: "models/silero_vad.onnx") {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Check bundle resources directly (Bazel bundles VAD without models/ prefix)
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = "\(resourcePath)/silero_vad.onnx"
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        return nil
    }

    /// Search paths in priority order: App Support, cwd relatives, bundle resources.
    private static func searchPaths(suffix: String) -> [String] {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path

        let cwd = FileManager.default.currentDirectoryPath
        var paths = [
            "\(appSupport)/\(suffix)",
            "\(cwd)/\(suffix)",
            "\(cwd)/../\(suffix)",
            "\(cwd)/../../\(suffix)",
        ]

        if let resourcePath = Bundle.main.resourcePath {
            paths.append("\(resourcePath)/\(suffix)")
        }

        return paths
    }

    static var installBase: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Chirp").path
        return "\(appSupport)/models"
    }

    // MARK: - Download

    /// Starts parallel downloads of the model archive and VAD file.
    func download() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let modelTask = session!.downloadTask(with: variant.downloadURL)
        let vadTask = session!.downloadTask(with: Self.vadURL)

        modelTask.taskDescription = "model"
        vadTask.taskDescription = "vad"

        modelTask.resume()
        vadTask.resume()
    }

    // MARK: - Delegate state

    private var modelDone = false
    private var vadDone = false
    private var downloadError: Error?

    /// Reports model download progress (0→0.7). VAD is small and not tracked separately.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard downloadTask.taskDescription == "model",
              totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 0.7
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
            downloadError = error
            return
        }

        if downloadTask.taskDescription == "vad" {
            let dest = "\(installBase)/silero_vad.onnx"
            try? FileManager.default.removeItem(atPath: dest)
            do {
                try FileManager.default.copyItem(atPath: location.path, toPath: dest)
            } catch {
                downloadError = error
            }
            vadDone = true
            checkAllDone()
            return
        }

        // Model archive: extract tar.bz2
        onProgress(0.7)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", location.path, "-C", installBase]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                downloadError = ChirpError.extractionFailed
            }
        } catch {
            downloadError = error
        }

        onProgress(0.95)
        modelDone = true
        checkAllDone()
    }

    /// Called when both downloads finish. Validates extracted files and reports result.
    private func checkAllDone() {
        guard modelDone && vadDone else { return }

        if let error = downloadError {
            onComplete(.failure(error))
            return
        }

        let modelDir = "\(Self.installBase)/\(variant.modelDirName)"
        let vadPath = "\(Self.installBase)/silero_vad.onnx"

        guard FileManager.default.fileExists(atPath: modelDir + "/\(variant.checkFile)"),
              FileManager.default.fileExists(atPath: vadPath) else {
            onComplete(.failure(ChirpError.modelFilesNotFound))
            return
        }

        onProgress(1.0)
        onComplete(.success(ModelPaths(modelDir: modelDir, vadPath: vadPath, variant: variant)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadError = error
            if task.taskDescription == "vad" { vadDone = true }
            else { modelDone = true }
            checkAllDone()
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
