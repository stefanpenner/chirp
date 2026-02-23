// ChirpApp.swift — Core state machine.
// AppState owns the full lifecycle: model download → loading → ready ⇄ recording.
//
// State machine (AppState.Status):
//
//                       cancel
//   ┌──────────────┐──────────→┌─────────────┐
//   │ downloading  │           │ needsModel  │
//   │  (progress)  │           └──────┬──────┘
//   └──────┬───────┘            fn   │
//          │ model found              ▼
//          ▼                  ┌──────────────┐
//   ┌───────────────┐  ←─────│ downloading  │ (re-entry)
//   │ loadingModel  │        └──────────────┘
//   └───────┬───────┘
//    success│  failure
//     ┌─────┘    └──→ ┌────────┐
//     ▼                │ error  │
//   ┌───────┐  retry   └────────┘
//   │ ready │←────────────┘
//   └───┬───┘←──────────────────────────────────┐
//  fn press│                                ESC │
//        ▼                                      │
//   ┌───────────┐  fn release  ┌──────────────┐ │
//   │ recording ├─────────────→│ transcribing ├─┘
//   └─────┬─────┘  ←───────────┴──────┬───────┘
//      ESC│         fn press          │ flush + linger
//         └──→ ready                  └──→ ready
//
// recording ↔ transcribing can cycle (fn press/release) within the
// same session. Text accumulates across cycles. Session ends via
// linger timeout (natural) or ESC (cancel).

import SwiftUI
import Foundation

// MARK: - AppState

@MainActor
@Observable
public final class AppState {
    public enum Status {
        case needsModel            // no model on disk; idle until user initiates download
        case downloading(Double)   // 0.0 … 1.0
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    public var status: Status = .loadingModel
    public var transcribedText: String = ""
    public var speculativeText: String = ""
    public var audioLevel: Float = 0
    let audioRecorder: any AudioRecording
    private(set) var transcriber: any TranscriberProtocol
    let textInserter: any TextInserting
    public var downloadNudge: Bool = false
    public var hotkeyConfig: HotkeyConfig = .saved
    public let inputDeviceManager = InputDeviceManager()
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?
    var hotkeyRecorderPanel: HotkeyRecorderPanel?
    private var modelManager: ModelManager?
    var transcriberFactory: () -> any TranscriberProtocol = { Transcriber() }
    private var peekTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var audioConsumerTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var pipelineNeedsRebuild = false

    // MARK: - Pipeline

    /// The active transcription pipeline. Built from aiSettings via rebuildPipeline().
    private(set) var pipeline: any TranscriptionPipeline

    /// Whether the current pipeline types text incrementally during recording.
    /// False for cloud STT or LLM post-processing (text typed once on flush).
    public private(set) var pipelineTypesIncrementally: Bool = true

    /// Whether the current pipeline supports speculative preview during recording.
    /// False for cloud STT or LLM post-processing.
    public private(set) var pipelineSupportsPreview: Bool = true

    // MARK: - AI Settings

    /// Cloud AI configuration (endpoints, modes). Persisted to UserDefaults.
    public var aiSettings: AISettings = AISettings()

    /// Settings window controller. Created lazily on first showSettings().
    var settingsWindowController: SettingsWindowController?

    /// Monotonically increasing session counter. Incremented each time
    /// startRecording() is called. Checked after every await to discard
    /// work from a previous recording session.
    private var recordingSession: UInt64 = 0

    /// How long the overlay lingers after final text before hiding (nanoseconds).
    /// Injectable for tests.
    var lingerDuration: UInt64 = 800_000_000

    /// Generation counter — incremented each time a committed segment arrives.
    /// Peek previews that were started before the latest commit are discarded.
    private var commitGen = 0

    public convenience init() {
        let transcriber = Transcriber()
        self.init(audioRecorder: AudioRecorder(), transcriber: transcriber, textInserter: TextInserter(), startListening: false)
        self.modelFileCheck = {
            ModelManager.findExisting() != nil
        }
        self.aiSettings = .saved
        rebuildPipeline()

        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopRecording() },
            onCancel: { [weak self] in self?.cancelSession() }
        )
        textInserter.checkAccessibilityPermission()
        ensureModel()
    }

    init(
        audioRecorder: any AudioRecording,
        transcriber: any TranscriberProtocol,
        textInserter: any TextInserting,
        startListening: Bool = true
    ) {
        self.audioRecorder = audioRecorder
        self.transcriber = transcriber
        self.textInserter = textInserter
        self.pipeline = OfflineTranscriptionPipeline(transcriber: transcriber)
        guard startListening else { return }
        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopRecording() },
            onCancel: { [weak self] in self?.cancelSession() }
        )
        textInserter.checkAccessibilityPermission()
        ensureModel()
    }

    // MARK: - Model lifecycle

    /// If the model is on disk, load it immediately; otherwise download first.
    private func ensureModel() {
        if let paths = ModelManager.findExisting() {
            loadTranscriber(paths: paths)
            return
        }

        status = .downloading(0)
        overlayPanel?.showOverlay()
        modelManager = ModelManager(
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.status = .downloading(progress) }
                }
            },
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let paths):
                            self?.loadTranscriber(paths: paths)
                        case .failure(let error):
                            self?.status = .error(error.localizedDescription)
                        }
                        self?.modelManager = nil
                    }
                }
            }
        )
        modelManager?.download()
    }

    func loadTranscriber(paths: ModelPaths) {
        status = .loadingModel
        let transcriber = self.transcriber
        Task { [weak self] in
            let ok = await transcriber.initialize(paths: paths)
            guard let self else { return }
            if ok {
                let micGranted = await self.audioRecorder.requestMicrophoneAccess()
                if micGranted {
                    self.status = .ready
                    self.overlayPanel?.hideOverlay()
                    self.audioRecorder.prepare()
                } else {
                    self.status = .error("Microphone access denied — enable in System Settings → Privacy & Security → Microphone")
                    self.overlayPanel?.hideOverlay()
                }
            } else {
                self.status = .error("Failed to initialize transcriber")
            }
        }
    }

    var modelFileCheck: () -> Bool = { true }

    /// Cancel an in-flight download. Returns to idle `.needsModel` state.
    public func cancelDownload() {
        guard case .downloading = status else { return }
        modelManager?.cancel()
        modelManager = nil
        status = .needsModel
        overlayPanel?.hideOverlay()
    }

    /// Start or retry downloading the model.
    public func retryDownload() {
        switch status {
        case .error, .needsModel: ensureModel()
        default: break
        }
    }

    // MARK: - Pipeline management

    /// Rebuild the transcription pipeline from the active AI mode.
    /// Called when AI settings change in the Settings UI.
    public func rebuildPipeline() {
        switch status {
        case .recording, .transcribing:
            pipelineNeedsRebuild = true
            return
        default:
            break
        }
        pipelineNeedsRebuild = false
        guard let mode = aiSettings.activeMode else {
            pipeline = OfflineTranscriptionPipeline(transcriber: transcriber)
            pipelineTypesIncrementally = true
            pipelineSupportsPreview = true
            return
        }

        let postProcessor = buildPostProcessor(for: mode)
        let actuallyUsesLLM = !(postProcessor is RegexPostProcessor || postProcessor is PassthroughPostProcessor)

        switch mode.transcriptionMode {
        case .offline:
            pipeline = OfflineTranscriptionPipeline(transcriber: transcriber, postProcessor: postProcessor)
            pipelineTypesIncrementally = !actuallyUsesLLM
            pipelineSupportsPreview = true
        case .cloud:
            if let sttClient = buildSTTClient(for: mode) {
                pipeline = CloudTranscriptionPipeline(sttClient: sttClient, postProcessor: postProcessor, localTranscriber: transcriber)
                pipelineTypesIncrementally = false
                pipelineSupportsPreview = true
            } else {
                pipeline = OfflineTranscriptionPipeline(transcriber: transcriber, postProcessor: postProcessor)
                pipelineTypesIncrementally = !actuallyUsesLLM
                pipelineSupportsPreview = true
            }
        }
    }

    private func buildPostProcessor(for mode: AIMode) -> any TextPostProcessing {
        switch mode.postProcessingMode {
        case .none:
            return PassthroughPostProcessor()
        case .regex:
            return RegexPostProcessor()
        case .llm:
            guard let client = buildLLMClient(for: mode) else { return RegexPostProcessor() }
            return LLMPostProcessor(client: client, systemPrompt: mode.llmSystemPrompt)
        case .regexThenLLM:
            guard let client = buildLLMClient(for: mode) else { return RegexPostProcessor() }
            return ChainedPostProcessor(
                llm: LLMPostProcessor(client: client, systemPrompt: mode.llmSystemPrompt)
            )
        case .offlineLLM:
            guard let t5 = buildT5PostProcessor() else { return RegexPostProcessor() }
            return OfflineLLMPostProcessor(t5: t5)
        case .regexThenOfflineLLM:
            guard let t5 = buildT5PostProcessor() else { return RegexPostProcessor() }
            return ChainedOfflinePostProcessor(t5: t5)
        }
    }

    private func buildT5PostProcessor() -> T5PostProcessor? {
        guard let modelDir = T5ModelManager.findExisting() else { return nil }
        do {
            return try T5PostProcessor(modelDir: modelDir)
        } catch {
            Log.model.error("Failed to initialize T5 post-processor: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildLLMClient(for mode: AIMode) -> (any LLMClient)? {
        guard let endpoint = aiSettings.endpoint(for: mode.llmEndpointID),
              let apiKey = KeychainHelper.load(account: endpoint.apiKeyRef),
              let model = mode.llmModel, !model.isEmpty else { return nil }
        switch endpoint.apiProtocol {
        case .openAI:
            return OpenAILLMClient(baseURL: endpoint.baseURL, apiKey: apiKey, model: model)
        case .anthropic:
            return AnthropicLLMClient(baseURL: endpoint.baseURL, apiKey: apiKey, model: model)
        case .google:
            return GoogleLLMClient(baseURL: endpoint.baseURL, apiKey: apiKey, model: model)
        }
    }

    private func buildSTTClient(for mode: AIMode) -> (any STTClient)? {
        guard let endpoint = aiSettings.endpoint(for: mode.sttEndpointID),
              let apiKey = KeychainHelper.load(account: endpoint.apiKeyRef),
              let model = mode.sttModel, !model.isEmpty else { return nil }
        switch endpoint.apiProtocol {
        case .openAI:
            return OpenAISTTClient(baseURL: endpoint.baseURL, apiKey: apiKey, model: model)
        case .google:
            return GoogleSTTClient(baseURL: endpoint.baseURL, apiKey: apiKey)
        case .anthropic:
            return nil
        }
    }

    // MARK: - Settings

    public func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appState: self)
        }
        settingsWindowController?.show()
    }

    // MARK: - Hotkey

    public func updateInputDevice(uid: String?) {
        inputDeviceManager.selectedDeviceUID = uid
        audioRecorder.selectInputDevice(inputDeviceManager.selectedDeviceID)
    }

    public func updateHotkey(_ config: HotkeyConfig) {
        hotkeyConfig = config
        hotkeyManager?.updateConfig(config)
    }

    public func showHotkeyRecorder() {
        if hotkeyRecorderPanel == nil {
            hotkeyRecorderPanel = HotkeyRecorderPanel(appState: self)
        }
        hotkeyRecorderPanel?.show()
    }

    // MARK: - Recording

    private func triggerDownloadNudge() {
        nudgeTask?.cancel()
        downloadNudge = true
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.downloadNudge = false
        }
    }

    func startRecording() {
        switch status {
        case .downloading, .loadingModel:
            triggerDownloadNudge()
            return
        case .needsModel:
            ensureModel()
            return
        case .ready:
            break
        case .transcribing:
            // Rejoin: fn pressed during finalization — resume recording
            // in the same session. Text accumulates.
            rejoinSession()
            return
        default:
            return
        }
        if !modelFileCheck() {
            ensureModel()
            return
        }
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        transcribedText = ""
        speculativeText = ""
        commitGen = 0
        recordingSession &+= 1
        let session = recordingSession
        status = .recording
        hotkeyManager?.sessionActive = true

        startConsumerAndAudio(session: session)
        startPeeking()

        overlayPanel?.showOverlay()
    }

    /// Rejoin an active transcribing session — cancel the old consumer
    /// (which is in flush or linger sleep), keep accumulated text, and
    /// start a fresh audio stream + consumer in the same session.
    private func rejoinSession() {
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        audioContinuation?.finish()
        audioContinuation = nil
        audioRecorder.stopRecording()

        let session = recordingSession  // same session — no bump
        status = .recording
        hotkeyManager?.sessionActive = true

        startConsumerAndAudio(session: session)
        startPeeking()
    }

    /// Shared setup: creates a new audio stream, starts the recorder,
    /// and spawns the consumer task for the given session.
    private func startConsumerAndAudio(session: UInt64) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        audioContinuation = continuation

        audioRecorder.startRecording { samples in
            continuation.yield(samples)
        }

        let pipeline = self.pipeline
        let typesIncrementally = self.pipelineTypesIncrementally
        audioConsumerTask = Task { [weak self] in
            // Guaranteed to run before first feedAudio — no ordering race.
            await pipeline.resetVAD()

            for await samples in stream {
                guard !Task.isCancelled else { break }

                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
                let level = min(rms * 6, 1)

                let segments = await pipeline.feedAudio(samples: samples)

                // Session guard is sufficient — status may be .transcribing if
                // stopRecording() ran mid-feedAudio, and we must still process
                // those results (the VAD already popped them).
                guard let self, self.recordingSession == session else { break }

                self.audioLevel = level
                for text in segments {
                    guard !text.isEmpty else { continue }
                    self.commitGen += 1
                    self.speculativeText = ""
                    let needsSpace = !self.transcribedText.isEmpty
                    if needsSpace { self.transcribedText += " " }
                    self.transcribedText += text
                    if typesIncrementally {
                        self.textInserter.typeText(needsSpace ? " \(text)" : text)
                    }
                }
            }

            // Stream ended (stopRecording finished the continuation).
            // Flush any remaining audio the VAD hasn't emitted yet.
            guard !Task.isCancelled else { return }
            guard let self, self.recordingSession == session else { return }

            let remaining = await pipeline.flush()
            guard !Task.isCancelled else { return }
            guard self.recordingSession == session else { return }
            if !remaining.isEmpty {
                if typesIncrementally {
                    let needsSpace = !self.transcribedText.isEmpty
                    if needsSpace { self.transcribedText += " " }
                    self.transcribedText += remaining
                    self.textInserter.typeText(needsSpace ? " \(remaining)" : remaining)
                } else {
                    // Non-incremental: pipeline returns full processed text on flush
                    self.transcribedText = remaining
                    self.textInserter.typeText(remaining)
                }
            }
            self.audioLevel = 0
            self.hotkeyManager?.sessionActive = false
            if !self.transcribedText.isEmpty {
                try? await Task.sleep(nanoseconds: self.lingerDuration)
                guard !Task.isCancelled else { return }
                guard self.recordingSession == session else { return }
            }
            self.status = .ready
            self.overlayPanel?.hideOverlay()
            if self.pipelineNeedsRebuild {
                self.rebuildPipeline()
            }
        }
    }

    /// Polls the pipeline every 400 ms for a speculative preview of
    /// the current (uncommitted) audio. Discarded if a committed segment
    /// arrives in the meantime (checked via commitGen and recordingSession).
    private func startPeeking() {
        guard pipelineSupportsPreview else { return }
        let pipeline = self.pipeline
        let session = recordingSession
        peekTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { break }
                guard let self, self.recordingSession == session else { break }
                guard case .recording = self.status else { break }
                let gen = self.commitGen
                let preview = await pipeline.peekTranscription()
                guard self.recordingSession == session else { break }
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
        // Don't cancel audioConsumerTask — it will process any in-flight
        // feedAudio results, then flush remaining audio after the stream ends.
        // Stop the recorder before finishing the continuation so in-flight
        // I/O thread tap callbacks can still yield to the open continuation.
        audioRecorder.stopRecording()
        audioContinuation?.finish()
        audioContinuation = nil

        status = .transcribing
        speculativeText = ""
    }

    func cancelSession() {
        switch status {
        case .recording, .transcribing: break
        default: return
        }

        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        peekTask?.cancel()
        peekTask = nil
        audioContinuation?.finish()
        audioContinuation = nil
        audioRecorder.stopRecording()

        recordingSession &+= 1  // discard in-flight async work
        transcribedText = ""
        speculativeText = ""
        audioLevel = 0
        hotkeyManager?.sessionActive = false
        status = .ready
        overlayPanel?.hideOverlay()
        if pipelineNeedsRebuild {
            rebuildPipeline()
        }
    }
}
