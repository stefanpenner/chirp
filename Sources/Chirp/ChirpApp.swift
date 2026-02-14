import SwiftUI
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Status {
        case downloading(Double)
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    @Published var status: Status = .loadingModel
    @Published var transcribedText: String = ""

    let audioRecorder = AudioRecorder()
    let transcriber = Transcriber()
    let textInserter = TextInserter()
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?
    private var modelManager: ModelManager?

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    init() {
        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggleRecording()
        }
        textInserter.checkAccessibilityPermission()
        ensureModel()
    }

    private func ensureModel() {
        if let modelDir = ModelManager.findExistingModel() {
            loadTranscriber(modelDir: modelDir)
            return
        }

        // Model not found — download it
        status = .downloading(0)
        NSLog("Chirp: Model not found, downloading...")

        modelManager = ModelManager(
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.status = .downloading(progress)
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let modelDir):
                        NSLog("Chirp: Download complete")
                        self?.loadTranscriber(modelDir: modelDir)
                    case .failure(let error):
                        NSLog("Chirp: Download failed: %@", error.localizedDescription)
                        self?.status = .error(error.localizedDescription)
                    }
                    self?.modelManager = nil
                }
            }
        )
        modelManager?.download()
    }

    private func loadTranscriber(modelDir: String) {
        status = .loadingModel
        NSLog("Chirp: Loading model from: %@", modelDir)
        Task.detached { [weak self] in
            guard let self else { return }
            let ready = self.transcriber.initialize(modelDir: modelDir)
            await MainActor.run {
                if ready {
                    self.status = .ready
                } else {
                    self.status = .error("Failed to initialize transcriber")
                }
            }
        }
    }

    func toggleRecording() {
        switch status {
        case .ready:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        default:
            break
        }
    }

    private func startRecording() {
        transcribedText = ""
        status = .recording
        overlayPanel?.showOverlay()
        audioRecorder.startRecording()
    }

    private func stopRecordingAndTranscribe() {
        status = .transcribing
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

                self.status = .ready
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
            statusView
            Divider()
            Button("Quit Chirp") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.status {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading model...")
                    .font(.caption)
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        case .loadingModel:
            Text("Loading model...")
                .font(.caption)
                .foregroundColor(.orange)
        case .ready:
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
        case .error(let msg):
            Text("Error: \(msg)")
                .font(.caption)
                .foregroundColor(.red)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {}
}
