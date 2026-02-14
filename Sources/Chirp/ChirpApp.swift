import SwiftUI
import Foundation

@MainActor
@Observable
final class AppState {
    enum Status {
        case downloading(Double)
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    var status: Status = .loadingModel
    var transcribedText: String = ""
    var speculativeText: String = ""
    var audioLevel: Float = 0
    var selectedVariant: ModelVariant

    let audioRecorder: any AudioRecording
    private(set) var transcriber: any TranscriberProtocol
    let textInserter: any TextInserting
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?
    private var modelManager: ModelManager?
    private var peekTask: Task<Void, Never>?
    private var commitGen = 0

    init(
        audioRecorder: any AudioRecording = AudioRecorder(),
        transcriber: any TranscriberProtocol = Transcriber(),
        textInserter: any TextInserting = TextInserter()
    ) {
        self.audioRecorder = audioRecorder
        self.transcriber = transcriber
        self.textInserter = textInserter
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
        Task {
            let ok = await transcriber.initialize(paths: paths)
            self.status = ok ? .ready : .error("Failed to initialize transcriber")
        }
    }

    func startRecording() {
        guard case .ready = status else { return }
        transcribedText = ""
        speculativeText = ""
        commitGen = 0
        let transcriber = self.transcriber
        Task { await transcriber.resetVAD() }
        status = .recording
        overlayPanel?.showOverlay()

        audioRecorder.startRecording { [weak self] samples in
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            let level = min(rms * 6, 1)

            Task { @MainActor [weak self] in
                guard let self else { return }
                let segments = await transcriber.feedAudio(samples: samples)
                self.audioLevel = level
                for text in segments {
                    self.commitGen += 1
                    self.speculativeText = ""
                    let needsSpace = !self.transcribedText.isEmpty
                    if needsSpace { self.transcribedText += " " }
                    self.transcribedText += text
                    self.textInserter.typeText(needsSpace ? " \(text)" : text)
                }
            }
        }

        startPeeking()
    }

    private func startPeeking() {
        let transcriber = self.transcriber
        peekTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { break }
                guard let self, case .recording = self.status else { break }
                let gen = self.commitGen
                let preview = await transcriber.peekTranscription()
                guard case .recording = self.status else { break }
                guard self.commitGen == gen else { continue }
                self.speculativeText = preview ?? ""
            }
        }
    }

    func stopRecording() {
        guard case .recording = status else { return }
        peekTask?.cancel()
        peekTask = nil
        audioRecorder.stopRecording()
        status = .transcribing
        speculativeText = ""

        let transcriber = self.transcriber

        Task {
            let remaining = await transcriber.flush()
            if !remaining.isEmpty {
                let needsSpace = !self.transcribedText.isEmpty
                if needsSpace { self.transcribedText += " " }
                self.transcribedText += remaining
                self.textInserter.typeText(needsSpace ? " \(remaining)" : remaining)
            }
            self.audioLevel = 0
            self.status = .ready
            self.overlayPanel?.hideOverlay()
        }
    }
}

@main
struct ChirpApp: App {
    @State private var appState = AppState()

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
