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

    public enum ProcessingPhase {
        case none
        case transcribing
        case fixing
    }

    public var status: Status = .loadingModel
    public var processingPhase: ProcessingPhase = .none
    public var transcribedText: String = ""
    public var speculativeText: String = ""
    public var audioLevel: Float = 0
    private(set) var audioRecorder: any AudioRecording
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

    // MARK: - Speaker Verification

    /// Speaker enrollment data (reference embedding, threshold). Persisted to UserDefaults.
    public var speakerEnrollment: SpeakerEnrollment = SpeakerEnrollment()
    private var speakerVerifier: SpeakerVerifier?

    /// Whether Apple Voice Processing IO is enabled for noise suppression.
    public var noiseReductionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(noiseReductionEnabled, forKey: "chirp.noiseReduction")
            audioRecorder.voiceProcessingEnabled = noiseReductionEnabled
            reprepareRecorderIfIdle()
        }
    }

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

    /// Multi-level undo/redo stack of typed deltas (spoken scratch/redo that).
    private var editStack = EditStack()

    /// Sticky capitalization mode for new commits (Dragon-style caps on / all caps / no caps).
    /// Observable for overlay badge when non-normal.
    private(set) var capsMode: CapsMode = .normal

    /// Multi-step "replace that": next content undoes last phrase then inserts.
    /// Observable for overlay badge. Dual of specs/ReplaceThat.tla.
    private(set) var awaitingReplace = false

    /// Normalized form of the last committed non-command segment (dedup echoes).
    private var lastCommittedNormalized = ""

    public convenience init() {
        let transcriber = Transcriber()
        self.init(audioRecorder: AudioRecorder(), transcriber: transcriber, textInserter: TextInserter(), startListening: false)
        self.modelFileCheck = {
            ModelManager.findExisting() != nil
        }
        self.aiSettings = .saved
        self.speakerEnrollment = .saved

        // Load audio processing settings from UserDefaults
        let defaults = UserDefaults.standard
        let nr = defaults.object(forKey: "chirp.noiseReduction") as? Bool ?? true
        noiseReductionEnabled = nr
        audioRecorder.voiceProcessingEnabled = nr

        loadSpeakerVerifierIfNeeded()
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
                    // Engine is lazily prepared in startRecording().
                    // Preparing eagerly would enable VP's aggregate device,
                    // dimming system audio output before the user records.
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

    /// Test / injection hook: install a pipeline and typing policy.
    func installPipelineForTesting(
        _ pipeline: any TranscriptionPipeline,
        typesIncrementally: Bool
    ) {
        self.pipeline = pipeline
        self.pipelineTypesIncrementally = typesIncrementally
        self.pipelineSupportsPreview = typesIncrementally
    }

    /// Rebuild the transcription pipeline from the active AI mode.
    /// Called when AI settings change in the Settings UI.
    public func rebuildPipeline() {
        let phase = SessionDecision.phase(from: status)
        if PipelineRebuildDecision.shouldDefer(phase: phase) {
            pipelineNeedsRebuild = true
            return
        }
        pipelineNeedsRebuild = false
        guard let mode = aiSettings.activeMode else {
            let verifier: (any SpeakerVerifying)? = (speakerEnrollment.isEnabled && speakerEnrollment.isEnrolled) ? speakerVerifier : nil
            pipeline = OfflineTranscriptionPipeline(transcriber: transcriber, speakerVerifier: verifier, speakerThreshold: speakerEnrollment.threshold)
            pipelineTypesIncrementally = true
            pipelineSupportsPreview = true
            return
        }

        let postProcessor = buildPostProcessor(for: mode)
        let actuallyUsesLLM = TextPostProcessingPolicy.defersTypingUntilFlush(postProcessor)

        // Speaker verification: pass verifier to pipeline when enabled + enrolled
        let verifier: (any SpeakerVerifying)? = (speakerEnrollment.isEnabled && speakerEnrollment.isEnrolled) ? speakerVerifier : nil
        let threshold = speakerEnrollment.threshold

        switch mode.transcriptionMode {
        case .offline:
            pipeline = OfflineTranscriptionPipeline(transcriber: transcriber, postProcessor: postProcessor, speakerVerifier: verifier, speakerThreshold: threshold)
            pipelineTypesIncrementally = !actuallyUsesLLM
            pipelineSupportsPreview = true
        case .cloud:
            if let sttClient = buildSTTClient(for: mode) {
                pipeline = CloudTranscriptionPipeline(sttClient: sttClient, postProcessor: postProcessor, localTranscriber: transcriber, speakerVerifier: verifier, speakerThreshold: threshold)
                pipelineTypesIncrementally = false
                pipelineSupportsPreview = true
            } else {
                pipeline = OfflineTranscriptionPipeline(transcriber: transcriber, postProcessor: postProcessor, speakerVerifier: verifier, speakerThreshold: threshold)
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

    // MARK: - Speaker Verification Lifecycle

    /// Load speaker verifier if enrollment is enabled and model is available.
    func loadSpeakerVerifierIfNeeded() {
        guard speakerEnrollment.isEnabled,
              speakerEnrollment.isEnrolled,
              let modelPath = SpeakerModelManager.findExisting() else {
            speakerVerifier = nil
            return
        }
        let verifier = SpeakerVerifier()
        speakerVerifier = verifier
        Task {
            do {
                try await verifier.loadModel(path: modelPath)
                if let ref = speakerEnrollment.referenceEmbedding {
                    await verifier.setReferenceEmbedding(ref)
                }
                rebuildPipeline()
                Log.speaker.info("Speaker verifier loaded and ready")
            } catch {
                Log.speaker.error("Failed to load speaker verifier: \(error.localizedDescription)")
                speakerVerifier = nil
            }
        }
    }

    /// Enroll the user's voice from multiple recordings.
    public func enrollSpeaker(recordings: [[Float]]) async {
        guard let verifier = speakerVerifier else {
            Log.speaker.error("Cannot enroll: speaker verifier not loaded")
            return
        }
        var embeddings: [[Float]] = []
        for recording in recordings {
            do {
                let emb = try await verifier.extractEmbedding(samples: recording)
                embeddings.append(emb)
            } catch {
                Log.speaker.error("Failed to extract embedding during enrollment: \(error.localizedDescription)")
            }
        }
        guard !embeddings.isEmpty else { return }
        await verifier.enroll(embeddings: embeddings)
        // Average the embeddings to store as reference
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<min(dim, emb.count) { avg[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        for i in 0..<dim { avg[i] /= n }
        let ref = SpeakerVerifier.l2Normalize(avg)

        speakerEnrollment.referenceEmbedding = ref
        speakerEnrollment.phraseCount = recordings.count
        speakerEnrollment.enrolledAt = Date()
        speakerEnrollment.save()
        rebuildPipeline()
    }

    /// Clear enrollment data and disable speaker verification.
    public func clearEnrollment() {
        speakerEnrollment.referenceEmbedding = nil
        speakerEnrollment.phraseCount = 0
        speakerEnrollment.enrolledAt = nil
        speakerEnrollment.save()
        Task { await speakerVerifier?.setReferenceEmbedding(nil) }
        rebuildPipeline()
    }

    /// Tear down and re-prepare the recorder when not recording (needed for voice processing mode change).
    private func reprepareRecorderIfIdle() {
        switch status {
        case .recording, .transcribing: return
        default: break
        }
        audioRecorder.selectInputDevice(inputDeviceManager.selectedDeviceID)
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
            // SessionDecision.canStartRecording(.ready)
            break
        case .transcribing:
            // Rejoin: fn pressed during finalization — resume recording
            // in the same session. Text accumulates.
            guard SessionDecision.canRejoin(.transcribing) else { return }
            rejoinSession()
            return
        default:
            return
        }
        // Extra pure-gate check for the ready → recording path
        guard SessionDecision.canStartRecording(.ready) else { return }
        if !modelFileCheck() {
            ensureModel()
            return
        }
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        transcribedText = ""
        speculativeText = ""
        commitGen = 0
        editStack.clear()
        capsMode = .normal
        awaitingReplace = false
        lastCommittedNormalized = ""
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
                    self.applyCommittedText(text, typesIncrementally: typesIncrementally)
                }
            }

            // Stream ended (stopRecording finished the continuation).
            // Flush any remaining audio the VAD hasn't emitted yet.
            guard !Task.isCancelled else { return }
            guard let self, self.recordingSession == session else { return }

            let remaining = await pipeline.flush { [weak self] in
                Task { @MainActor in self?.processingPhase = .fixing }
            }
            guard !Task.isCancelled else { return }
            guard self.recordingSession == session else { return }
            self.processingPhase = .none
            self.speculativeText = ""
            if !remaining.isEmpty {
                if typesIncrementally {
                    self.applyCommittedText(remaining, typesIncrementally: true)
                } else {
                    // Non-incremental: pipeline returns full processed text on flush.
                    // Commands still mutate buffer/stack; do not force incremental typing.
                    switch DictationCommand.parse(remaining) {
                    case .scratchThat:
                        self.awaitingReplace = false
                        self.performScratchThat(typesIncrementally: false)
                    case .replaceThat:
                        self.performArmReplace()
                    case .deleteLastWord:
                        self.awaitingReplace = false
                        self.performDeleteLastWord(typesIncrementally: false)
                    case .clearAll:
                        self.awaitingReplace = false
                        self.performClearAll(typesIncrementally: false)
                    case .pressEnter:
                        self.performKeyInsert("\n", typesIncrementally: false)
                    case .pressTab:
                        self.performKeyInsert("\t", typesIncrementally: false)
                    case .copyThat:
                        self.performCopyThat()
                    case .pasteThat:
                        self.performPasteThat(typesIncrementally: false)
                    case .redoThat:
                        self.performRedoThat(typesIncrementally: false)
                    case .setCapsMode(let mode):
                        self.capsMode = mode
                    case .capThat:
                        self.performTransformLastWord(
                            CapsTransform.capitalizeWord,
                            typesIncrementally: false
                        )
                    case .allCapsThat:
                        self.performTransformLastWord(
                            CapsTransform.upperWord,
                            typesIncrementally: false
                        )
                    case .noCapsThat:
                        self.performTransformLastWord(
                            CapsTransform.lowerWord,
                            typesIncrementally: false
                        )
                    case .titleCaseThat:
                        self.performTransformLastPhrase(
                            CapsTransform.titleCaseWords,
                            typesIncrementally: false
                        )
                    case .sentenceCaseThat:
                        self.performTransformLastPhrase(
                            CapsTransform.sentenceCase,
                            typesIncrementally: false
                        )
                    case .noSpaceThat:
                        self.performNoSpaceThat(typesIncrementally: false)
                    case .none:
                        // One-shot type: replace buffer + stack so scratch undoes the
                        // whole batch (mid-session segments were not typed/pushed).
                        self.awaitingReplace = false
                        let text = CapsTransform.apply(remaining, mode: self.capsMode)
                        self.editStack.clear()
                        self.transcribedText = text
                        if !text.isEmpty {
                            self.textInserter.typeText(text)
                            self.editStack.push(text)
                        }
                        self.lastCommittedNormalized = TranscriptNormalize.key(text)
                    }
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

    /// Apply a committed ASR segment: either a spoken command or normal text.
    private func applyCommittedText(_ text: String, typesIncrementally: Bool) {
        switch DictationCommand.parse(text) {
        case .scratchThat:
            awaitingReplace = false
            performScratchThat(typesIncrementally: typesIncrementally)
        case .replaceThat:
            performArmReplace()
        case .deleteLastWord:
            awaitingReplace = false
            performDeleteLastWord(typesIncrementally: typesIncrementally)
        case .clearAll:
            awaitingReplace = false
            performClearAll(typesIncrementally: typesIncrementally)
        case .pressEnter:
            performKeyInsert("\n", typesIncrementally: typesIncrementally)
        case .pressTab:
            performKeyInsert("\t", typesIncrementally: typesIncrementally)
        case .copyThat:
            performCopyThat()
        case .pasteThat:
            performPasteThat(typesIncrementally: typesIncrementally)
        case .redoThat:
            performRedoThat(typesIncrementally: typesIncrementally)
        case .setCapsMode(let mode):
            capsMode = mode
        case .capThat:
            performTransformLastWord(CapsTransform.capitalizeWord, typesIncrementally: typesIncrementally)
        case .allCapsThat:
            performTransformLastWord(CapsTransform.upperWord, typesIncrementally: typesIncrementally)
        case .noCapsThat:
            performTransformLastWord(CapsTransform.lowerWord, typesIncrementally: typesIncrementally)
        case .titleCaseThat:
            performTransformLastPhrase(CapsTransform.titleCaseWords, typesIncrementally: typesIncrementally)
        case .sentenceCaseThat:
            performTransformLastPhrase(CapsTransform.sentenceCase, typesIncrementally: typesIncrementally)
        case .noSpaceThat:
            performNoSpaceThat(typesIncrementally: typesIncrementally)
        case .none:
            // Multi-step replace: undo last phrase, then insert replacement.
            if ReplaceDecision.shouldUndoBeforeCommit(awaitingReplace: awaitingReplace) {
                awaitingReplace = false
                performScratchThat(typesIncrementally: typesIncrementally)
            }
            // Skip consecutive identical segments (VAD/ASR echo under noise)
            let shaped = CapsTransform.apply(text, mode: capsMode)
            let norm = TranscriptNormalize.key(shaped)
            if !norm.isEmpty, norm == lastCommittedNormalized {
                Log.transcription.debug("Skipping duplicate segment: \"\(shaped)\"")
                return
            }
            let joined = SegmentJoiner.append(existing: transcribedText, next: shaped)
            transcribedText = joined.full
            if typesIncrementally {
                textInserter.typeText(joined.delta)
            }
            editStack.push(joined.delta)
            lastCommittedNormalized = norm
        }
    }

    /// Arm multi-step replace; text stays until the next content phrase arrives.
    private func performArmReplace() {
        guard ReplaceDecision.canArm(hasLastPhrase: editStack.canUndo) else { return }
        awaitingReplace = true
    }

    /// One-shot transform of the last typed phrase (EditStack top delta).
    /// Falls back to last word when the stack is empty.
    private func performTransformLastPhrase(
        _ transform: (String) -> String,
        typesIncrementally: Bool
    ) {
        guard let oldSuffix = editStack.lastDelta, !oldSuffix.isEmpty else {
            performTransformLastWord(transform, typesIncrementally: typesIncrementally)
            return
        }
        guard transcribedText.hasSuffix(oldSuffix) else {
            performTransformLastWord(transform, typesIncrementally: typesIncrementally)
            return
        }
        let newSuffix = transform(oldSuffix)
        guard newSuffix != oldSuffix else { return }

        transcribedText = String(transcribedText.dropLast(oldSuffix.count)) + newSuffix
        if typesIncrementally {
            textInserter.deleteBackward(count: oldSuffix.count)
            textInserter.typeText(newSuffix)
        }
        if editStack.dropTrailingSuffix(oldSuffix) {
            editStack.push(newSuffix)
        } else {
            editStack.clear()
            editStack.push(newSuffix)
        }
        lastCommittedNormalized = ""
    }

    /// Remove the space before the last word ("no space that" → PeytonDavis).
    private func performNoSpaceThat(typesIncrementally: Bool) {
        // Prefer last stack delta if it has a leading space (joiner delta).
        if let last = editStack.lastDelta, last.first?.isWhitespace == true {
            performTransformLastPhrase(CapsTransform.stripLeadingSpace, typesIncrementally: typesIncrementally)
            return
        }
        // Otherwise strip space before the last word in the buffer.
        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var buffer = transcribedText
        while buffer.last?.isWhitespace == true {
            buffer.removeLast()
        }
        guard let lastSpace = buffer.lastIndex(where: { $0.isWhitespace }) else { return }
        let wordStart = buffer.index(after: lastSpace)
        var start = wordStart
        if start > transcribedText.startIndex {
            let before = transcribedText.index(before: start)
            if transcribedText[before].isWhitespace {
                start = before
            }
        }
        let oldSuffix = String(transcribedText[start...])
        let newSuffix = CapsTransform.stripLeadingSpace(oldSuffix)
        guard newSuffix != oldSuffix else { return }

        transcribedText = String(transcribedText[..<start]) + newSuffix
        if typesIncrementally {
            textInserter.deleteBackward(count: oldSuffix.count)
            textInserter.typeText(newSuffix)
        }
        if editStack.dropTrailingSuffix(oldSuffix) {
            editStack.push(newSuffix)
        } else {
            editStack.clear()
            editStack.push(newSuffix)
        }
        lastCommittedNormalized = ""
    }

    /// One-shot transform of the last whitespace-delimited word (cap that / all caps that).
    private func performTransformLastWord(
        _ transform: (String) -> String,
        typesIncrementally: Bool
    ) {
        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var buffer = transcribedText
        while buffer.last?.isWhitespace == true {
            buffer.removeLast()
        }
        let wordStart: String.Index
        let includeLeadingSpace: Bool
        if let lastSpace = buffer.lastIndex(where: { $0.isWhitespace }) {
            wordStart = buffer.index(after: lastSpace)
            includeLeadingSpace = true
        } else {
            wordStart = transcribedText.startIndex
            includeLeadingSpace = false
        }
        var start = wordStart
        if includeLeadingSpace, start > transcribedText.startIndex {
            let before = transcribedText.index(before: start)
            if transcribedText[before].isWhitespace {
                start = before
            }
        }
        let oldSuffix = String(transcribedText[start...])
        let spacePrefix = oldSuffix.prefix(while: { $0.isWhitespace })
        let core = String(oldSuffix.dropFirst(spacePrefix.count))
        guard !core.isEmpty else { return }
        let newCore = transform(core)
        guard newCore != core else { return }
        let newSuffix = String(spacePrefix) + newCore

        transcribedText = String(transcribedText[..<start]) + newSuffix
        if typesIncrementally {
            textInserter.deleteBackward(count: oldSuffix.count)
            textInserter.typeText(newSuffix)
        }
        if editStack.dropTrailingSuffix(oldSuffix) {
            editStack.push(newSuffix)
        } else {
            // Stack can't explain suffix — wipe and record new suffix only
            editStack.clear()
            editStack.push(newSuffix)
        }
        lastCommittedNormalized = ""
    }

    private func performKeyInsert(_ s: String, typesIncrementally: Bool) {
        transcribedText += s
        if typesIncrementally {
            textInserter.typeText(s)
        }
        editStack.push(s)
        lastCommittedNormalized = ""
    }

    /// Copy session transcript to the pasteboard (does not type).
    private func performCopyThat() {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInserter.copyToClipboard(text)
    }

    /// Paste clipboard into the focused app; also append into session buffer when known.
    private func performPasteThat(typesIncrementally: Bool) {
        // Prefer native ⌘V path so apps get their own paste handling.
        textInserter.pasteFromClipboard()
        if let clip = textInserter.clipboardString(), !clip.isEmpty {
            transcribedText += clip
            editStack.push(clip)
            lastCommittedNormalized = ""
        }
    }

    /// Undo the last typed segment (multi-level; Dragon-style "scratch that").
    private func performScratchThat(typesIncrementally: Bool) {
        guard let delta = editStack.undo() else { return }
        let remove = min(delta.count, transcribedText.count)
        if remove > 0 {
            transcribedText = String(transcribedText.dropLast(remove))
            if typesIncrementally {
                textInserter.deleteBackward(count: remove)
            }
        }
        lastCommittedNormalized = ""
    }

    /// Redo the last scratched segment ("redo that").
    private func performRedoThat(typesIncrementally: Bool) {
        guard let delta = editStack.redo() else { return }
        transcribedText += delta
        if typesIncrementally {
            textInserter.typeText(delta)
        }
        lastCommittedNormalized = ""
    }

    /// Delete the last whitespace-delimited word from the session transcript.
    /// Prefers adjusting EditStack so prior segments remain undoable and
    /// "redo that" can restore the deleted word.
    private func performDeleteLastWord(typesIncrementally: Bool) {
        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Drop trailing spaces from buffer, then the last word
        var buffer = transcribedText
        while buffer.last?.isWhitespace == true {
            buffer.removeLast()
        }
        guard let lastSpace = buffer.lastIndex(where: { $0.isWhitespace }) else {
            // Single word — clear all
            let remove = transcribedText.count
            let removed = transcribedText
            transcribedText = ""
            if typesIncrementally, remove > 0 {
                textInserter.deleteBackward(count: remove)
            }
            if !editStack.dropTrailingSuffix(removed) {
                editStack.clear()
            }
            lastCommittedNormalized = ""
            return
        }
        let wordStart = buffer.index(after: lastSpace)
        // Also remove one trailing space before the word if present
        var start = wordStart
        if start > transcribedText.startIndex {
            let before = transcribedText.index(before: start)
            if transcribedText[before].isWhitespace {
                start = before
            }
        }
        let removed = String(transcribedText[start...])
        let remove = removed.count
        transcribedText = String(transcribedText[..<start])
        if typesIncrementally, remove > 0 {
            textInserter.deleteBackward(count: remove)
        }
        // Keep multi-level undo when stack explains the deleted suffix
        if !editStack.dropTrailingSuffix(removed) {
            editStack.clear()
        }
        lastCommittedNormalized = ""
    }

    /// Clear the entire session transcript (spoken "clear all").
    private func performClearAll(typesIncrementally: Bool) {
        let remove = transcribedText.count
        guard remove > 0 else { return }
        transcribedText = ""
        if typesIncrementally {
            textInserter.deleteBackward(count: remove)
        }
        editStack.clear()
        lastCommittedNormalized = ""
    }

    /// Polls the pipeline for a speculative preview of uncommitted audio.
    /// Active speech: ~250ms (snappier partials). Idle: ~500ms to save CPU.
    /// Discarded if a committed segment arrives mid-peek (commitGen).
    private func startPeeking() {
        guard pipelineSupportsPreview else { return }
        let pipeline = self.pipeline
        let session = recordingSession
        peekTask = Task { [weak self] in
            var idleMisses = 0
            while !Task.isCancelled {
                let sleepNs = DecodePolicy.peekSleepNs(idleMisses: idleMisses)
                try? await Task.sleep(nanoseconds: sleepNs)
                guard !Task.isCancelled else { break }
                guard let self, self.recordingSession == session else { break }
                guard case .recording = self.status else { break }
                let gen = self.commitGen
                let preview = await pipeline.peekTranscription()
                guard self.recordingSession == session else { break }
                guard case .recording = self.status else { break }
                guard self.commitGen == gen else {
                    idleMisses = 0
                    continue
                }
                // Only update when we have a new preview — keep existing
                // speculative text visible when VAD flickers to non-detected.
                if let preview {
                    idleMisses = 0
                    self.speculativeText = preview
                } else {
                    idleMisses += 1
                }
            }
        }
    }

    func stopRecording() {
        // Guard matches specs/SessionMachine.tla StopRecording / SessionDecision
        guard let phase = SessionDecision.phase(from: status),
              SessionDecision.canStopRecording(phase) else { return }

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
        processingPhase = .transcribing
        // Keep speculativeText visible until flush result replaces it,
        // so the user doesn't see a blank overlay while waiting.
    }

    func cancelSession() {
        // Guard matches specs/SessionMachine.tla Cancel / SessionDecision
        guard let phase = SessionDecision.phase(from: status),
              SessionDecision.canCancel(phase) else { return }

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
        editStack.clear()
        lastCommittedNormalized = ""
        audioLevel = 0
        processingPhase = .none
        hotkeyManager?.sessionActive = false
        status = .ready
        overlayPanel?.hideOverlay()
        if pipelineNeedsRebuild {
            rebuildPipeline()
        }
    }
}
