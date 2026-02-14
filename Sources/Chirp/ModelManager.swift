import Foundation

struct ModelPaths {
    let modelDir: String
    let vadPath: String
}

final class ModelManager: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    static let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
    static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelName).tar.bz2")!
    static let vadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!

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

    static func findExisting() -> ModelPaths? {
        guard let modelDir = findModelDir() else { return nil }
        guard let vadPath = findVADPath() else { return nil }
        return ModelPaths(modelDir: modelDir, vadPath: vadPath)
    }

    private static func findModelDir() -> String? {
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/encoder.int8.onnx") {
            return envDir
        }

        for path in searchPaths(suffix: "models/\(modelName)") {
            if FileManager.default.fileExists(atPath: path + "/encoder.int8.onnx") {
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
        return nil
    }

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

    func download() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let modelTask = session!.downloadTask(with: Self.modelURL)
        let vadTask = session!.downloadTask(with: Self.vadURL)

        modelTask.taskDescription = "model"
        vadTask.taskDescription = "vad"

        modelTask.resume()
        vadTask.resume()
    }

    private var modelDone = false
    private var vadDone = false
    private var downloadError: Error?

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

    private func checkAllDone() {
        guard modelDone && vadDone else { return }

        if let error = downloadError {
            onComplete(.failure(error))
            return
        }

        let modelDir = "\(Self.installBase)/\(Self.modelName)"
        let vadPath = "\(Self.installBase)/silero_vad.onnx"

        guard FileManager.default.fileExists(atPath: modelDir + "/encoder.int8.onnx"),
              FileManager.default.fileExists(atPath: vadPath) else {
            onComplete(.failure(ChirpError.modelFilesNotFound))
            return
        }

        onProgress(1.0)
        onComplete(.success(ModelPaths(modelDir: modelDir, vadPath: vadPath)))
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
