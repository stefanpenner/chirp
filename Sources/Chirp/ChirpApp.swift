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
    @Published var speculativeText: String = ""
    @Published var audioLevel: Float = 0
    @Published var selectedVariant: ModelVariant

    let audioRecorder = AudioRecorder()
    private(set) var transcriber = Transcriber()
    let textInserter = TextInserter()
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?
    private var modelManager: ModelManager?
    private var peekTask: Task<Void, Never>?
    private var commitGen = 0

    init() {
        selectedVariant = ModelVariant.saved
        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopRecording() }
        )
        textInserter.checkAccessibilityPermission()
        ensureModel(variant: selectedVariant)
    }

    func switchVariant(_ variant: ModelVariant) {
        guard variant != selectedVariant else { return }
        guard case .ready = status else { return }

        selectedVariant = variant
        ModelVariant.saved = variant

        // Create a fresh transcriber and load the new model
        transcriber = Transcriber()
        ensureModel(variant: variant)
    }

    private func ensureModel(variant: ModelVariant) {
        if let paths = ModelManager.findExisting(variant: variant) {
            loadTranscriber(paths: paths)
            return
        }

        status = .downloading(0)
        modelManager = ModelManager(
            variant: variant,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.status = .downloading(progress) }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let paths):
                        self?.loadTranscriber(paths: paths)
                    case .failure(let error):
                        self?.status = .error(error.localizedDescription)
                    }
                    self?.modelManager = nil
                }
            }
        )
        modelManager?.download()
    }

    private func loadTranscriber(paths: ModelPaths) {
        status = .loadingModel
        let transcriber = self.transcriber
        Task.detached {
            let ok = transcriber.initialize(paths: paths)
            await MainActor.run { [weak self] in
                self?.status = ok ? .ready : .error("Failed to initialize transcriber")
            }
        }
    }

    private func startRecording() {
        guard case .ready = status else { return }
        transcribedText = ""
        speculativeText = ""
        commitGen = 0
        transcriber.resetVAD()
        status = .recording
        overlayPanel?.showOverlay()

        let transcriber = self.transcriber
        let textInserter = self.textInserter

        audioRecorder.startRecording { [weak self] samples in
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            let level = min(rms * 6, 1)

            Task.detached {
                let segments = transcriber.feedAudio(samples: samples)
                await MainActor.run {
                    guard let self else { return }
                    self.audioLevel = level
                    for text in segments {
                        self.commitGen += 1
                        self.speculativeText = ""
                        let needsSpace = !self.transcribedText.isEmpty
                        if needsSpace { self.transcribedText += " " }
                        self.transcribedText += text
                        textInserter.typeText(needsSpace ? " \(text)" : text)
                    }
                }
            }
        }

        startPeeking()
    }

    private func startPeeking() {
        let transcriber = self.transcriber
        peekTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
                guard !Task.isCancelled else { break }
                guard let self, case .recording = self.status else { break }
                let gen = self.commitGen
                let preview = await Task.detached { transcriber.peekTranscription() }.value
                guard case .recording = self.status else { break }
                guard self.commitGen == gen else { continue }
                self.speculativeText = preview ?? ""
            }
        }
    }

    private func stopRecording() {
        guard case .recording = status else { return }
        peekTask?.cancel()
        peekTask = nil
        audioRecorder.stopRecording()
        status = .transcribing
        speculativeText = ""

        let transcriber = self.transcriber
        let textInserter = self.textInserter

        Task.detached {
            let remaining = transcriber.flush()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !remaining.isEmpty {
                    let needsSpace = !self.transcribedText.isEmpty
                    if needsSpace { self.transcribedText += " " }
                    self.transcribedText += remaining
                    textInserter.typeText(needsSpace ? " \(remaining)" : remaining)
                }
                self.audioLevel = 0
                self.status = .ready
                self.overlayPanel?.hideOverlay()
            }
        }
    }
}

@main
struct ChirpApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "mic.fill") {
            statusView
            Divider()
            modelPicker
            Divider()
            Button("Quit Chirp") { NSApplication.shared.terminate(nil) }
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
            Text("Loading model...").font(.caption).foregroundColor(.orange)
        case .ready:
            Text("Ready (hold fn)").font(.caption).foregroundColor(.secondary)
        case .recording:
            Text("Recording...").font(.caption).foregroundColor(.red)
        case .transcribing:
            Text("Finalizing...").font(.caption).foregroundColor(.orange)
        case .error(let msg):
            Text("Error: \(msg)").font(.caption).foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        Text("Model").font(.caption).foregroundColor(.secondary)
        ForEach(ModelVariant.allCases, id: \.self) { variant in
            Button {
                appState.switchVariant(variant)
            } label: {
                HStack {
                    Text(variant.displayName)
                    if variant == appState.selectedVariant {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(!isReady)
        }
    }

    private var isReady: Bool {
        if case .ready = appState.status { return true }
        return false
    }
}
