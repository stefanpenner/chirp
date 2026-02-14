import SwiftUI
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RecordingState {
        case idle
        case recording
        case transcribing
    }

    @Published var recordingState: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var isTranscriberReady: Bool = false

    let audioRecorder = AudioRecorder()
    let transcriber = Transcriber()
    let textInserter = TextInserter()
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?

    init() {
        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggleRecording()
        }
        textInserter.checkAccessibilityPermission()
        initializeTranscriber()
    }

    private func initializeTranscriber() {
        guard let modelDir = findModelDir() else {
            print("Warning: Model directory not found. Run 'make setup' to download the model.")
            print("  Set CHIRP_MODEL_DIR env var or place models in the working directory.")
            return
        }

        NSLog("Chirp: Loading model from: %@", modelDir)
        Task.detached { [weak self] in
            guard let self else { return }
            let ready = self.transcriber.initialize(modelDir: modelDir)
            await MainActor.run {
                self.isTranscriberReady = ready
                if !ready {
                    print("Warning: Transcriber failed to initialize.")
                }
            }
        }
    }

    private func findModelDir() -> String? {
        // Check environment variable first
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/encoder.int8.onnx") {
            return envDir
        }

        // Look for model relative to the working directory
        let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/models/\(modelName)",
            "\(cwd)/../models/\(modelName)",
            "\(cwd)/../../models/\(modelName)",
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate + "/encoder.int8.onnx") {
                return candidate
            }
        }

        // Check next to the executable
        if let resourcePath = Bundle.main.resourcePath {
            let bundleCandidate = "\(resourcePath)/models/\(modelName)"
            if FileManager.default.fileExists(atPath: bundleCandidate + "/encoder.int8.onnx") {
                return bundleCandidate
            }
        }

        return nil
    }

    func toggleRecording() {
        switch recordingState {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        guard isTranscriberReady else {
            print("Transcriber not ready — cannot record")
            return
        }
        transcribedText = ""
        recordingState = .recording
        overlayPanel?.showOverlay()
        audioRecorder.startRecording()
    }

    private func stopRecordingAndTranscribe() {
        recordingState = .transcribing
        let samples = audioRecorder.stopRecording()

        let transcriber = self.transcriber
        Task.detached {
            let text = transcriber.transcribe(samples: samples)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transcribedText = text

                if !text.isEmpty {
                    self.textInserter.insertText(text)
                }

                self.recordingState = .idle
                self.overlayPanel?.hideOverlay()
            }
        }
    }
}

@main
struct ChirpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "mic.fill") {
            if !appState.isTranscriberReady {
                Text("Loading model...")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                switch appState.recordingState {
                case .idle:
                    Text("Ready (Option+Space)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .recording:
                    Text("Recording...")
                        .font(.caption)
                        .foregroundColor(.red)
                case .transcribing:
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            Button("Quit Chirp") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App setup happens in AppState init via @StateObject
    }
}
