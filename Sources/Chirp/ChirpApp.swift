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

    /// Apply VAD endpoint settings (pause length / sensitivity) to the live transcriber.
    /// Call from Settings when the user moves endpointing sliders.
    public func applyVadSettings() {
        Task { await transcriber.reconfigureVAD() }
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

    /// Clock for "insert date" / "insert time". Injectable so tests never touch
    /// process-global InsertStamp.nowProvider (parallel suite races).
    var nowProvider: () -> Date = { Date() }

    /// Timezone for insert date/time stamps. Injectable for deterministic tests.
    var timeZoneProvider: () -> TimeZone = { .current }

    /// Generation counter — incremented each time a committed segment arrives.
    /// Peek previews that were started before the latest commit are discarded.
    private var commitGen = 0

    /// Multi-level undo/redo stack of typed deltas (spoken scratch/redo that).
    private var editStack = EditStack()

    /// Sticky capitalization mode for new commits (Dragon-style caps on / all caps / no caps).
    /// Observable for overlay badge when non-normal.
    private(set) var capsMode: CapsMode = .normal

    /// One-shot "cap next": capitalize first word of the next content commit, then clear.
    /// Observable for overlay badge. Dual of specs/CapNext.tla.
    private(set) var capitalizeNextWord = false

    /// Sticky spell mode for new commits (Dragon/Mac letter packing).
    /// Observable for overlay badge when on. Dual of specs/SpellMode.tla.
    private(set) var spellMode: SpellMode = .off

    /// Sticky no-space mode for new commits (empty separators between segments).
    /// Observable for overlay badge when on. Dual of specs/NoSpaceMode.tla.
    /// Does not pack letters (that is spell mode).
    private(set) var noSpaceMode: NoSpaceMode = .off

    /// Multi-step "replace that": next content undoes last phrase then inserts.
    /// Observable for overlay badge. Dual of specs/ReplaceThat.tla.
    private(set) var awaitingReplace = false

    /// On-demand AI cleanup in flight (menu / hotkey / spoken "clean that up").
    public private(set) var isCleaningUp = false
    private var cleanupTask: Task<Void, Never>?

    /// Test hook: inject a post-processor for on-demand cleanup (avoids real T5/LLM).
    var cleanupProcessorOverride: (any TextPostProcessing)?

    /// Buffer range currently selected in the host (select that / first sentence / …).
    /// Next content splices this range so session buffer matches type-over. Dual of SelectionCommit.tla.
    private var sessionSelection: (start: Int, length: Int)? = nil

    /// Session caret offset after go-to / unit move (nil = end of buffer).
    /// Mid-buffer content inserts here so host and session stay dual. Dual of GoToPhrase.tla.
    private var sessionCaret: Int? = nil

    /// Normalized form of the last committed non-command segment (dedup echoes).
    private var lastCommittedNormalized = ""

    /// Progressive sentence navigation index within the session buffer.
    /// `nil` = caret conceptually at end of buffer (dual of SentenceCursor index = -1).
    /// Non-nil = 0-based sentence under caret (at content start of that sentence).
    private var sentenceNavIndex: Int? = nil

    /// True when a sentence selection is active (select first/last/next).
    /// After `clearSelection`, caret is at end of that sentence; after move, at start.
    private var sentenceSelectionActive = false

    /// Progressive paragraph navigation index (select/move/delete next paragraph).
    /// `nil` = caret at end; non-nil = paragraph under cursor (dual of ParagraphCursor).
    private var paragraphNavIndex: Int? = nil

    /// True when a paragraph selection is active (select first/last/next).
    /// After `clearSelection`, caret is at end of that paragraph; after move, at start.
    private var paragraphSelectionActive = false

    /// Progressive line navigation index (select/delete next line).
    /// `nil` = caret at end; non-nil = line under cursor.
    private var lineNavIndex: Int? = nil

    /// True when a line selection is active (select first/last/next).
    private var lineSelectionActive = false

    /// Progressive word navigation index (select next/previous word walk).
    /// `nil` = end / unknown; non-nil = 0-based word under selection (WordCursor.tla).
    private var wordNavIndex: Int? = nil

    /// True when a word selection is active (select next/previous/last word).
    private var wordSelectionActive = false

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
            onCancel: { [weak self] in self?.cancelSession() },
            onCleanup: { [weak self] in self?.runAICleanup() }
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
            onCancel: { [weak self] in self?.cancelSession() },
            onCleanup: { [weak self] in self?.runAICleanup() }
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

    /// Post-processor for on-demand AI cleanup (menu / hotkey / spoken).
    /// Prefers active-mode cloud LLM, else offline T5, else regex.
    private func buildCleanupPostProcessor() -> any TextPostProcessing {
        if let mode = aiSettings.activeMode {
            switch mode.postProcessingMode {
            case .llm, .regexThenLLM:
                if let client = buildLLMClient(for: mode) {
                    return LLMPostProcessor(client: client, systemPrompt: mode.llmSystemPrompt)
                }
            case .offlineLLM, .regexThenOfflineLLM:
                if let t5 = buildT5PostProcessor() {
                    return OfflineLLMPostProcessor(t5: t5)
                }
            case .none, .regex:
                break
            }
        }
        if let t5 = buildT5PostProcessor() {
            return OfflineLLMPostProcessor(t5: t5)
        }
        return RegexPostProcessor()
    }

    /// Human-readable hold chord for UI (e.g. "fn+C"). Dual: AICleanupTriggerDecision.
    public var aiCleanupChordLabel: String {
        AICleanupTriggerDecision.holdChordLabel(holdKeyLabel: hotkeyConfig.label)
    }

    /// On-demand AI cleanup of selection / last phrase / session buffer.
    /// Triggers: hold-to-talk + C, menu, ⌘⇧U, or spoken "clean that up".
    public func runAICleanup() {
        let hasText = !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard AICleanupTriggerDecision.canStart(
            hasText: hasText,
            isCleaningUp: isCleaningUp || cleanupTask != nil
        ) else { return }

        let scope = AICleanupDecision.resolve(
            buffer: transcribedText,
            selectionStart: sessionSelection?.start,
            selectionLength: sessionSelection?.length,
            lastDelta: editStack.lastDelta
        )
        guard scope != .empty else { return }

        let sourceText: String
        switch scope {
        case .selection(_, _, let text), .lastPhrase(let text), .fullBuffer(let text):
            sourceText = text
        case .empty:
            return
        }

        let processor = cleanupProcessorOverride ?? buildCleanupPostProcessor()
        let rewriteHost: Bool
        switch status {
        case .ready:
            // Session ended; host already has the typed text.
            rewriteHost = true
        case .recording, .transcribing:
            rewriteHost = AICleanupDecision.shouldRewriteHost(
                typesIncrementally: pipelineTypesIncrementally
            )
        default:
            return
        }

        isCleaningUp = true
        processingPhase = .fixing
        overlayPanel?.showOverlay()

        cleanupTask = Task { @MainActor [weak self] in
            defer {
                self?.cleanupTask = nil
                self?.isCleaningUp = false
                self?.processingPhase = .none
            }
            do {
                let cleaned = try await processor.process(sourceText)
                guard let self, !Task.isCancelled else { return }
                let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty, result != sourceText else { return }
                self.applyCleanupResult(scope: scope, cleaned: result, rewriteHost: rewriteHost)
            } catch {
                Log.general.error("AI cleanup failed: \(error.localizedDescription)")
            }
            // Hide overlay only if we are idle (menu/hotkey after session).
            if case .ready = self?.status {
                self?.overlayPanel?.hideOverlay()
            }
        }
    }

    /// Apply cleaned text for the resolved scope into buffer + optional host.
    private func applyCleanupResult(
        scope: AICleanupScope,
        cleaned: String,
        rewriteHost: Bool
    ) {
        switch scope {
        case .empty:
            return

        case .selection(let start, let length, let old):
            guard cleaned != old,
                  let newText = SelectionCommitDecision.bufferAfterRangeReplace(
                    buffer: transcribedText,
                    start: start,
                    length: length,
                    replacement: cleaned
                  ) else { return }
            if rewriteHost {
                moveToSessionOffset(start)
                textInserter.selectForward(count: length)
                textInserter.typeText(cleaned)
            }
            applyPhraseEditResult(
                newText: newText,
                matchStart: start,
                matchLength: length,
                stackPush: cleaned
            )

        case .lastPhrase(let old):
            guard cleaned != old, transcribedText.hasSuffix(old) else { return }
            transcribedText = String(transcribedText.dropLast(old.count)) + cleaned
            if rewriteHost {
                textInserter.deleteBackward(count: old.count)
                textInserter.typeText(cleaned)
            }
            if editStack.dropTrailingSuffix(old) {
                editStack.push(cleaned)
            } else {
                editStack.clear()
                editStack.push(cleaned)
            }
            lastCommittedNormalized = ""
            sessionSelection = nil
            sessionCaret = nil
            // Progressive nav is invalid after a trailing rewrite.
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
            lineNavIndex = nil
            lineSelectionActive = false
            wordNavIndex = nil
            wordSelectionActive = false

        case .fullBuffer(let old):
            guard cleaned != old else { return }
            if rewriteHost {
                let n = transcribedText.count
                if n > 0 {
                    textInserter.deleteBackward(count: n)
                }
                textInserter.typeText(cleaned)
            }
            transcribedText = cleaned
            editStack.clear()
            editStack.push(cleaned)
            lastCommittedNormalized = ""
            sessionSelection = nil
            sessionCaret = nil
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
            lineNavIndex = nil
            lineSelectionActive = false
            wordNavIndex = nil
            wordSelectionActive = false
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
        capitalizeNextWord = false
        spellMode = .off
        noSpaceMode = .off
        awaitingReplace = false
        sessionSelection = nil
        sessionCaret = nil
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
        wordNavIndex = nil
        wordSelectionActive = false
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
                    case .scratchThat(let count):
                        self.awaitingReplace = false
                        self.performScratchThat(count: count, typesIncrementally: false)
                    case .replaceThat:
                        self.performArmReplace()
                    case .replacePhrase(let target, let replacement):
                        self.awaitingReplace = false
                        self.performReplacePhrase(
                            target: target,
                            replacement: replacement,
                            typesIncrementally: false
                        )
                    case .deletePhrase(let target):
                        self.awaitingReplace = false
                        self.performDeletePhrase(target: target, typesIncrementally: false)
                    case .deleteLastWord:
                        self.awaitingReplace = false
                        self.performDeleteLastWord(typesIncrementally: false)
                    case .deleteLastWords(let count):
                        self.awaitingReplace = false
                        self.performDeleteLastWords(count: count, typesIncrementally: false)
                    case .deleteLastSentence:
                        self.awaitingReplace = false
                        self.performDeleteTrailingSelection(
                            selected: TranscriptSelection.lastSentence(self.transcribedText),
                            typesIncrementally: false
                        )
                    case .deleteNextSentence:
                        self.awaitingReplace = false
                        self.performDeleteNextSentence(typesIncrementally: false)
                    case .deleteFirstSentence:
                        self.awaitingReplace = false
                        self.performDeleteFirstSentence(typesIncrementally: false)
                    case .deleteLastParagraph:
                        self.awaitingReplace = false
                        self.performDeleteTrailingSelection(
                            selected: TranscriptSelection.lastParagraph(self.transcribedText),
                            typesIncrementally: false
                        )
                    case .deleteNextParagraph:
                        self.awaitingReplace = false
                        self.performDeleteNextParagraph(typesIncrementally: false)
                    case .deleteFirstParagraph:
                        self.awaitingReplace = false
                        self.performDeleteFirstParagraph(typesIncrementally: false)
                    case .deleteLastLine:
                        self.awaitingReplace = false
                        self.performDeleteTrailingSelection(
                            selected: TranscriptSelection.lastLine(self.transcribedText),
                            typesIncrementally: false
                        )
                    case .deleteNextLine:
                        self.awaitingReplace = false
                        self.performDeleteNextLine(typesIncrementally: false)
                    case .deleteFirstLine:
                        self.awaitingReplace = false
                        self.performDeleteFirstLine(typesIncrementally: false)
                    case .clearAll:
                        self.awaitingReplace = false
                        self.performClearAll(typesIncrementally: false)
                    case .pressEnter(let count):
                        self.performPressEnter(count: count, typesIncrementally: false)
                    case .pressTab(let count):
                        self.performPressTab(count: count, typesIncrementally: false)
                    case .pressSpace(let count):
                        self.performPressSpace(count: count, typesIncrementally: false)
                    case .pressBackspace(let count):
                        self.performPressBackspace(count: count)
                    case .pressEscape:
                        self.performPressEscape()
                    case .pressUndo:
                        self.performPressUndo()
                    case .pressRedo:
                        self.performPressRedo()
                    case .pressForwardDelete(let count):
                        self.performPressForwardDelete(count: count)
                    case .insertDate:
                        self.performKeyInsert(self.stampDate(), typesIncrementally: false)
                    case .insertTime:
                        self.performKeyInsert(self.stampTime(), typesIncrementally: false)
                    case .copyThat:
                        self.performCopyThat()
                    case .pasteThat:
                        self.performPasteThat(typesIncrementally: false)
                    case .duplicateThat:
                        self.performDuplicateThat(typesIncrementally: false)
                    case .redoThat(let count):
                        self.performRedoThat(count: count, typesIncrementally: false)
                    case .setCapsMode(let mode):
                        self.capsMode = mode
                    case .setSpellMode(let mode):
                        self.spellMode = mode
                    case .setNoSpaceMode(let mode):
                        self.noSpaceMode = mode
                    case .spellThat:
                        self.performSpellThat(typesIncrementally: false)
                    case .capThat:
                        self.performTransformLastWord(
                            CapsTransform.capitalizeWord,
                            typesIncrementally: false
                        )
                    case .capNext:
                        self.capitalizeNextWord = true
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
                    case .aiCleanup:
                        self.awaitingReplace = false
                        self.runAICleanup()
                    case .selectThat:
                        self.performSelectThat(typesIncrementally: false)
                    case .selectPhrase(let target):
                        self.performSelectPhrase(target: target, typesIncrementally: false)
                    case .goToPhrase(let target):
                        self.performGoToPhrase(target: target, after: false, typesIncrementally: false)
                    case .goAfterPhrase(let target):
                        self.performGoToPhrase(target: target, after: true, typesIncrementally: false)
                    case .resumeWith(let target):
                        self.awaitingReplace = false
                        self.performResumeWith(target: target, typesIncrementally: false)
                    case .selectLastWord:
                        self.performSelectLastWord(typesIncrementally: false)
                    case .selectLastWords(let count):
                        self.performSelectLastWords(count: count, typesIncrementally: false)
                    case .selectNextWord:
                        self.performSelectWord(direction: .right, typesIncrementally: false)
                    case .selectPreviousWord:
                        self.performSelectWord(direction: .left, typesIncrementally: false)
                    case .deleteNextWord:
                        self.performDeleteWord(direction: .right)
                    case .deletePreviousWord:
                        self.performDeleteWord(direction: .left)
                    case .selectPreviousWords(let count):
                        self.performSelectWords(direction: .left, count: count, typesIncrementally: false)
                    case .selectNextWords(let count):
                        self.performSelectWords(direction: .right, count: count, typesIncrementally: false)
                    case .deletePreviousWords(let count):
                        self.performDeleteWords(direction: .left, count: count)
                    case .deleteNextWords(let count):
                        self.performDeleteWords(direction: .right, count: count)
                    case .selectPreviousCharacters(let count):
                        self.performSelectCharacters(direction: .left, count: count)
                    case .selectNextCharacters(let count):
                        self.performSelectCharacters(direction: .right, count: count)
                    case .deletePreviousCharacters(let count):
                        self.awaitingReplace = false
                        self.performDeletePreviousCharacters(count: count, typesIncrementally: false)
                    case .deleteNextCharacters(let count):
                        self.performDeleteNextCharacters(count: count)
                    case .deleteLastSentences(let count):
                        self.awaitingReplace = false
                        self.performDeleteLastSentences(count: count, typesIncrementally: false)
                    case .deleteLastParagraphs(let count):
                        self.awaitingReplace = false
                        self.performDeleteLastParagraphs(count: count, typesIncrementally: false)
                    case .deleteLastLines(let count):
                        self.awaitingReplace = false
                        self.performDeleteLastLines(count: count, typesIncrementally: false)
                    case .selectLastSentences(let count):
                        self.performSelectLastUnits(kind: .sentence, count: count, typesIncrementally: false)
                    case .selectLastParagraphs(let count):
                        self.performSelectLastUnits(kind: .paragraph, count: count, typesIncrementally: false)
                    case .selectLastLines(let count):
                        self.performSelectLastUnits(kind: .line, count: count, typesIncrementally: false)
                    case .selectNextSentences(let count):
                        self.performSelectNextUnits(kind: .sentence, count: count, typesIncrementally: false)
                    case .selectNextParagraphs(let count):
                        self.performSelectNextUnits(kind: .paragraph, count: count, typesIncrementally: false)
                    case .selectNextLines(let count):
                        self.performSelectNextUnits(kind: .line, count: count, typesIncrementally: false)
                    case .deleteNextSentences(let count):
                        self.awaitingReplace = false
                        self.performDeleteNextUnits(kind: .sentence, count: count, typesIncrementally: false)
                    case .deleteNextParagraphs(let count):
                        self.awaitingReplace = false
                        self.performDeleteNextUnits(kind: .paragraph, count: count, typesIncrementally: false)
                    case .deleteNextLines(let count):
                        self.awaitingReplace = false
                        self.performDeleteNextUnits(kind: .line, count: count, typesIncrementally: false)
                    case .selectLastSentence:
                        self.performSelectLastSentence(typesIncrementally: false)
                    case .selectFirstSentence:
                        self.performSelectFirstSentence(typesIncrementally: false)
                    case .selectNextSentence:
                        self.performSelectNextSentence(typesIncrementally: false)
                    case .selectPreviousSentence:
                        self.performSelectPreviousSentence(typesIncrementally: false)
                    case .selectLastParagraph:
                        self.performSelectLastParagraph(typesIncrementally: false)
                    case .selectFirstParagraph:
                        self.performSelectFirstParagraph(typesIncrementally: false)
                    case .selectNextParagraph:
                        self.performSelectNextParagraph(typesIncrementally: false)
                    case .selectPreviousParagraph:
                        self.performSelectPreviousParagraph(typesIncrementally: false)
                    case .selectLastLine:
                        self.performSelectLastLine(typesIncrementally: false)
                    case .selectFirstLine:
                        self.performSelectFirstLine(typesIncrementally: false)
                    case .selectNextLine:
                        self.performSelectNextLine(typesIncrementally: false)
                    case .selectPreviousLine:
                        self.performSelectPreviousLine(typesIncrementally: false)
                    case .selectAll:
                        self.performSelectAll(typesIncrementally: false)
                    case .unselectThat:
                        self.performUnselectThat()
                    case .boldThat:
                        self.performFormatThat(.bold, typesIncrementally: false)
                    case .italicThat:
                        self.performFormatThat(.italic, typesIncrementally: false)
                    case .underlineThat:
                        self.performFormatThat(.underline, typesIncrementally: false)
                    case .cutThat:
                        self.performCutThat(typesIncrementally: false)
                    case .moveLeftWord:
                        self.performMoveWord(direction: .left)
                    case .moveRightWord:
                        self.performMoveWord(direction: .right)
                    case .movePreviousWords(let count):
                        self.performMoveWords(direction: .left, count: count)
                    case .moveNextWords(let count):
                        self.performMoveWords(direction: .right, count: count)
                    case .movePreviousCharacters(let count):
                        self.performMoveCharacters(direction: .left, count: count)
                    case .moveNextCharacters(let count):
                        self.performMoveCharacters(direction: .right, count: count)
                    case .moveUpLines(let count):
                        self.performMoveLine(direction: .up, count: count)
                    case .moveDownLines(let count):
                        self.performMoveLine(direction: .down, count: count)
                    case .selectUpLines(let count):
                        self.performSelectLines(direction: .up, count: count)
                    case .selectDownLines(let count):
                        self.performSelectLines(direction: .down, count: count)
                    case .moveUpParagraphs(let count):
                        self.performMoveParagraphs(direction: .up, count: count)
                    case .moveDownParagraphs(let count):
                        self.performMoveParagraphs(direction: .down, count: count)
                    case .moveToPreviousLine:
                        self.performMoveToPreviousLine()
                    case .moveToNextLine:
                        self.performMoveToNextLine()
                    case .moveToStart:
                        self.performMoveToLineStart()
                    case .moveToEnd:
                        self.performMoveToLineEnd()
                    case .moveToDocumentStart:
                        self.performMoveToDocumentStart()
                    case .moveToDocumentEnd:
                        self.performMoveToDocumentEnd()
                    case .moveToSentenceStart:
                        self.performMoveToSentenceEdge(start: true)
                    case .moveToSentenceEnd:
                        self.performMoveToSentenceEdge(start: false)
                    case .moveToParagraphStart:
                        self.performMoveToParagraphEdge(start: true)
                    case .moveToParagraphEnd:
                        self.performMoveToParagraphEdge(start: false)
                    case .pageUp(let count):
                        self.performScrollPage(direction: .up, count: count)
                    case .pageDown(let count):
                        self.performScrollPage(direction: .down, count: count)
                    case .moveToPreviousSentence:
                        self.performMoveToPreviousSentence()
                    case .moveToNextSentence:
                        self.performMoveToNextSentence()
                    case .moveToPreviousParagraph:
                        self.performMoveToPreviousParagraph()
                    case .moveToNextParagraph:
                        self.performMoveToNextParagraph()
                    case .none:
                        // One-shot type: replace buffer + stack so scratch undoes the
                        // whole batch (mid-session segments were not typed/pushed).
                        self.awaitingReplace = false
                        let text = self.shapeContent(remaining).text
                        self.editStack.clear()
                        self.transcribedText = text
                        if !text.isEmpty {
                            self.textInserter.typeText(text)
                            self.editStack.push(text)
                        }
                        self.lastCommittedNormalized = TranscriptNormalize.key(text)
                        self.sentenceNavIndex = nil
                        self.sentenceSelectionActive = false
                        self.paragraphNavIndex = nil
                        self.paragraphSelectionActive = false
                        self.lineNavIndex = nil
                        self.lineSelectionActive = false
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
        case .scratchThat(let count):
            awaitingReplace = false
            performScratchThat(count: count, typesIncrementally: typesIncrementally)
        case .replaceThat:
            performArmReplace()
        case .replacePhrase(let target, let replacement):
            awaitingReplace = false
            performReplacePhrase(
                target: target,
                replacement: replacement,
                typesIncrementally: typesIncrementally
            )
        case .deletePhrase(let target):
            awaitingReplace = false
            performDeletePhrase(target: target, typesIncrementally: typesIncrementally)
        case .deleteLastWord:
            awaitingReplace = false
            performDeleteLastWord(typesIncrementally: typesIncrementally)
        case .deleteLastWords(let count):
            awaitingReplace = false
            performDeleteLastWords(count: count, typesIncrementally: typesIncrementally)
        case .deleteLastSentence:
            awaitingReplace = false
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastSentence(transcribedText),
                typesIncrementally: typesIncrementally
            )
        case .deleteFirstSentence:
            awaitingReplace = false
            performDeleteFirstSentence(typesIncrementally: typesIncrementally)
        case .deleteNextSentence:
            awaitingReplace = false
            performDeleteNextSentence(typesIncrementally: typesIncrementally)
        case .deleteLastParagraph:
            awaitingReplace = false
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastParagraph(transcribedText),
                typesIncrementally: typesIncrementally
            )
        case .deleteFirstParagraph:
            awaitingReplace = false
            performDeleteFirstParagraph(typesIncrementally: typesIncrementally)
        case .deleteNextParagraph:
            awaitingReplace = false
            performDeleteNextParagraph(typesIncrementally: typesIncrementally)
        case .deleteLastLine:
            awaitingReplace = false
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastLine(transcribedText),
                typesIncrementally: typesIncrementally
            )
        case .deleteFirstLine:
            awaitingReplace = false
            performDeleteFirstLine(typesIncrementally: typesIncrementally)
        case .deleteNextLine:
            awaitingReplace = false
            performDeleteNextLine(typesIncrementally: typesIncrementally)
        case .clearAll:
            awaitingReplace = false
            performClearAll(typesIncrementally: typesIncrementally)
        case .pressEnter(let count):
            performPressEnter(count: count, typesIncrementally: typesIncrementally)
        case .pressTab(let count):
            performPressTab(count: count, typesIncrementally: typesIncrementally)
        case .pressSpace(let count):
            performPressSpace(count: count, typesIncrementally: typesIncrementally)
        case .pressBackspace(let count):
            performPressBackspace(count: count)
        case .pressEscape:
            performPressEscape()
        case .pressUndo:
            performPressUndo()
        case .pressRedo:
            performPressRedo()
        case .pressForwardDelete(let count):
            performPressForwardDelete(count: count)
        case .insertDate:
            performKeyInsert(stampDate(), typesIncrementally: typesIncrementally)
        case .insertTime:
            performKeyInsert(stampTime(), typesIncrementally: typesIncrementally)
        case .copyThat:
            performCopyThat()
        case .pasteThat:
            performPasteThat(typesIncrementally: typesIncrementally)
        case .duplicateThat:
            performDuplicateThat(typesIncrementally: typesIncrementally)
        case .redoThat(let count):
            performRedoThat(count: count, typesIncrementally: typesIncrementally)
        case .setCapsMode(let mode):
            capsMode = mode
        case .setSpellMode(let mode):
            spellMode = mode
        case .setNoSpaceMode(let mode):
            noSpaceMode = mode
        case .spellThat:
            performSpellThat(typesIncrementally: typesIncrementally)
        case .capThat:
            performTransformLastWord(CapsTransform.capitalizeWord, typesIncrementally: typesIncrementally)
        case .capNext:
            capitalizeNextWord = true
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
        case .aiCleanup:
            awaitingReplace = false
            runAICleanup()
        case .selectThat:
            performSelectThat(typesIncrementally: typesIncrementally)
        case .selectPhrase(let target):
            performSelectPhrase(target: target, typesIncrementally: typesIncrementally)
        case .goToPhrase(let target):
            performGoToPhrase(target: target, after: false, typesIncrementally: typesIncrementally)
        case .goAfterPhrase(let target):
            performGoToPhrase(target: target, after: true, typesIncrementally: typesIncrementally)
        case .resumeWith(let target):
            awaitingReplace = false
            performResumeWith(target: target, typesIncrementally: typesIncrementally)
        case .selectLastWord:
            performSelectLastWord(typesIncrementally: typesIncrementally)
        case .selectLastWords(let count):
            performSelectLastWords(count: count, typesIncrementally: typesIncrementally)
        case .selectNextWord:
            performSelectWord(direction: .right, typesIncrementally: typesIncrementally)
        case .selectPreviousWord:
            performSelectWord(direction: .left, typesIncrementally: typesIncrementally)
        case .deleteNextWord:
            performDeleteWord(direction: .right)
        case .deletePreviousWord:
            performDeleteWord(direction: .left)
        case .selectPreviousWords(let count):
            performSelectWords(direction: .left, count: count, typesIncrementally: typesIncrementally)
        case .selectNextWords(let count):
            performSelectWords(direction: .right, count: count, typesIncrementally: typesIncrementally)
        case .deletePreviousWords(let count):
            performDeleteWords(direction: .left, count: count)
        case .deleteNextWords(let count):
            performDeleteWords(direction: .right, count: count)
        case .selectPreviousCharacters(let count):
            performSelectCharacters(direction: .left, count: count)
        case .selectNextCharacters(let count):
            performSelectCharacters(direction: .right, count: count)
        case .deletePreviousCharacters(let count):
            awaitingReplace = false
            performDeletePreviousCharacters(count: count, typesIncrementally: typesIncrementally)
        case .deleteNextCharacters(let count):
            performDeleteNextCharacters(count: count)
        case .deleteLastSentences(let count):
            awaitingReplace = false
            performDeleteLastSentences(count: count, typesIncrementally: typesIncrementally)
        case .deleteLastParagraphs(let count):
            awaitingReplace = false
            performDeleteLastParagraphs(count: count, typesIncrementally: typesIncrementally)
        case .deleteLastLines(let count):
            awaitingReplace = false
            performDeleteLastLines(count: count, typesIncrementally: typesIncrementally)
        case .selectLastSentences(let count):
            performSelectLastUnits(kind: .sentence, count: count, typesIncrementally: typesIncrementally)
        case .selectLastParagraphs(let count):
            performSelectLastUnits(kind: .paragraph, count: count, typesIncrementally: typesIncrementally)
        case .selectLastLines(let count):
            performSelectLastUnits(kind: .line, count: count, typesIncrementally: typesIncrementally)
        case .selectNextSentences(let count):
            performSelectNextUnits(kind: .sentence, count: count, typesIncrementally: typesIncrementally)
        case .selectNextParagraphs(let count):
            performSelectNextUnits(kind: .paragraph, count: count, typesIncrementally: typesIncrementally)
        case .selectNextLines(let count):
            performSelectNextUnits(kind: .line, count: count, typesIncrementally: typesIncrementally)
        case .deleteNextSentences(let count):
            awaitingReplace = false
            performDeleteNextUnits(kind: .sentence, count: count, typesIncrementally: typesIncrementally)
        case .deleteNextParagraphs(let count):
            awaitingReplace = false
            performDeleteNextUnits(kind: .paragraph, count: count, typesIncrementally: typesIncrementally)
        case .deleteNextLines(let count):
            awaitingReplace = false
            performDeleteNextUnits(kind: .line, count: count, typesIncrementally: typesIncrementally)
        case .selectLastSentence:
            performSelectLastSentence(typesIncrementally: typesIncrementally)
        case .selectFirstSentence:
            performSelectFirstSentence(typesIncrementally: typesIncrementally)
        case .selectNextSentence:
            performSelectNextSentence(typesIncrementally: typesIncrementally)
        case .selectPreviousSentence:
            performSelectPreviousSentence(typesIncrementally: typesIncrementally)
        case .selectLastParagraph:
            performSelectLastParagraph(typesIncrementally: typesIncrementally)
        case .selectFirstParagraph:
            performSelectFirstParagraph(typesIncrementally: typesIncrementally)
        case .selectNextParagraph:
            performSelectNextParagraph(typesIncrementally: typesIncrementally)
        case .selectPreviousParagraph:
            performSelectPreviousParagraph(typesIncrementally: typesIncrementally)
        case .selectLastLine:
            performSelectLastLine(typesIncrementally: typesIncrementally)
        case .selectFirstLine:
            performSelectFirstLine(typesIncrementally: typesIncrementally)
        case .selectNextLine:
            performSelectNextLine(typesIncrementally: typesIncrementally)
        case .selectPreviousLine:
            performSelectPreviousLine(typesIncrementally: typesIncrementally)
        case .selectAll:
            performSelectAll(typesIncrementally: typesIncrementally)
        case .unselectThat:
            performUnselectThat()
        case .boldThat:
            performFormatThat(.bold, typesIncrementally: typesIncrementally)
        case .italicThat:
            performFormatThat(.italic, typesIncrementally: typesIncrementally)
        case .underlineThat:
            performFormatThat(.underline, typesIncrementally: typesIncrementally)
        case .cutThat:
            performCutThat(typesIncrementally: typesIncrementally)
        case .moveLeftWord:
            performMoveWord(direction: .left)
        case .moveRightWord:
            performMoveWord(direction: .right)
        case .movePreviousWords(let count):
            performMoveWords(direction: .left, count: count)
        case .moveNextWords(let count):
            performMoveWords(direction: .right, count: count)
        case .movePreviousCharacters(let count):
            performMoveCharacters(direction: .left, count: count)
        case .moveNextCharacters(let count):
            performMoveCharacters(direction: .right, count: count)
        case .moveUpLines(let count):
            performMoveLine(direction: .up, count: count)
        case .moveDownLines(let count):
            performMoveLine(direction: .down, count: count)
        case .selectUpLines(let count):
            performSelectLines(direction: .up, count: count)
        case .selectDownLines(let count):
            performSelectLines(direction: .down, count: count)
        case .moveUpParagraphs(let count):
            performMoveParagraphs(direction: .up, count: count)
        case .moveDownParagraphs(let count):
            performMoveParagraphs(direction: .down, count: count)
        case .moveToPreviousLine:
            performMoveToPreviousLine()
        case .moveToNextLine:
            performMoveToNextLine()
        case .moveToStart:
            performMoveToLineStart()
        case .moveToEnd:
            performMoveToLineEnd()
        case .moveToDocumentStart:
            performMoveToDocumentStart()
        case .moveToDocumentEnd:
            performMoveToDocumentEnd()
        case .moveToSentenceStart:
            performMoveToSentenceEdge(start: true)
        case .moveToSentenceEnd:
            performMoveToSentenceEdge(start: false)
        case .moveToParagraphStart:
            performMoveToParagraphEdge(start: true)
        case .moveToParagraphEnd:
            performMoveToParagraphEdge(start: false)
        case .pageUp(let count):
            performScrollPage(direction: .up, count: count)
        case .pageDown(let count):
            performScrollPage(direction: .down, count: count)
        case .moveToPreviousSentence:
            performMoveToPreviousSentence()
        case .moveToNextSentence:
            performMoveToNextSentence()
        case .moveToPreviousParagraph:
            performMoveToPreviousParagraph()
        case .moveToNextParagraph:
            performMoveToNextParagraph()
        case .none:
            // Multi-step replace: undo last phrase, then insert replacement.
            if ReplaceDecision.shouldUndoBeforeCommit(awaitingReplace: awaitingReplace) {
                awaitingReplace = false
                sessionSelection = nil
                sessionCaret = nil
                performScratchThat(typesIncrementally: typesIncrementally)
            }
            // Skip consecutive identical segments (VAD/ASR echo under noise)
            let shaped = shapeContent(text)
            let norm = TranscriptNormalize.key(shaped.text)
            if !norm.isEmpty, norm == lastCommittedNormalized {
                Log.transcription.debug("Skipping duplicate segment: \"\(shaped.text)\"")
                return
            }
            // Selection type-over: splice range so buffer matches host overwrite.
            if let sel = sessionSelection,
               let replaced = SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: transcribedText,
                start: sel.start,
                length: sel.length,
                replacement: shaped.text
               ) {
                if SelectionCommitDecision.isTrailing(
                    start: sel.start,
                    length: sel.length,
                    bufferCount: transcribedText.count
                ) {
                    let suffix = String(transcribedText.suffix(sel.length))
                    if !editStack.dropTrailingSuffix(suffix) {
                        editStack.clear()
                    }
                } else {
                    // Middle replace cannot peel stack deltas reliably.
                    editStack.clear()
                }
                transcribedText = replaced
                if typesIncrementally {
                    // Host already has the selection; key events replace it in place.
                    textInserter.typeText(shaped.text)
                }
                if !shaped.text.isEmpty {
                    editStack.push(shaped.text)
                }
                lastCommittedNormalized = norm
                sessionSelection = nil
                sessionCaret = nil
                sentenceNavIndex = nil
                sentenceSelectionActive = false
                paragraphNavIndex = nil
                paragraphSelectionActive = false
                lineNavIndex = nil
                lineSelectionActive = false
                clearWordNav()
                return
            }
            sessionSelection = nil
            // Mid-buffer insert after go-to / go-after (host caret already mid).
            if SessionCaretDecision.isMidBuffer(
                caret: sessionCaret,
                bufferCount: transcribedText.count
            ),
               let caret = sessionCaret,
               let inserted = SessionCaretDecision.bufferAfterInsert(
                buffer: transcribedText,
                caret: caret,
                piece: shaped.text,
                preserveLeadingCase: shaped.preserveLeadingCase,
                emptySeparator: spellMode == .on || noSpaceMode.isOn
               ) {
                editStack.clear()
                transcribedText = inserted.text
                if typesIncrementally {
                    textInserter.typeText(inserted.delta)
                }
                if !inserted.delta.isEmpty {
                    editStack.push(inserted.delta)
                }
                lastCommittedNormalized = norm
                // Stay mid if still not at end; else clear (trailing again).
                sessionCaret = inserted.caret < transcribedText.count ? inserted.caret : nil
                sentenceNavIndex = nil
                sentenceSelectionActive = false
                paragraphNavIndex = nil
                paragraphSelectionActive = false
                lineNavIndex = nil
                lineSelectionActive = false
                clearWordNav()
                return
            }
            sessionCaret = nil
            // One-shot pack preserves case ("abc"/"John"); sticky also glues segments.
            // Spell mode and no-space mode both use empty separators (no letter packing
            // for no-space — that is spell mode only).
            let joined = SegmentJoiner.append(
                existing: transcribedText,
                next: shaped.text,
                preserveLeadingCase: shaped.preserveLeadingCase,
                emptySeparator: spellMode == .on || noSpaceMode.isOn
            )
            transcribedText = joined.full
            if typesIncrementally {
                textInserter.typeText(joined.delta)
            }
            editStack.push(joined.delta)
            lastCommittedNormalized = norm
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
            lineNavIndex = nil
            lineSelectionActive = false
            clearWordNav()
        }
    }

    /// Arm a buffer range for next content type-over (must match host selection).
    private func armSessionSelection(start: Int, length: Int) {
        guard SelectionCommitDecision.isInRange(
            start: start,
            length: length,
            bufferCount: transcribedText.count
        ) else {
            sessionSelection = nil
            return
        }
        sessionSelection = (start, length)
        // Selection type-over wins over insert-at-caret.
        sessionCaret = nil
    }

    /// Record session caret for mid-buffer insert (clears selection arm).
    /// `nil` / end-of-buffer → append mode (`sessionCaret = nil`).
    private func setSessionCaret(_ offset: Int) {
        sessionSelection = nil
        sessionCaret = offset < transcribedText.count ? offset : nil
        // Caret-only nav is independent of progressive word selection walk.
        wordNavIndex = nil
        wordSelectionActive = false
    }

    private func clearWordNav() {
        wordNavIndex = nil
        wordSelectionActive = false
    }

    /// Shape a content segment: one-shot "spell as …", sticky spell mode, or caps.
    /// One-shot does not change `spellMode`. Cap-next arms first word after sticky caps.
    private func shapeContent(_ text: String) -> (text: String, preserveLeadingCase: Bool) {
        if let packed = SpellTransform.oneShot(text) {
            // Cap-next still consumes on any content commit (including one-shot spell).
            if capitalizeNextWord {
                capitalizeNextWord = false
                return (CapsTransform.capitalizeFirstWord(packed), true)
            }
            return (packed, true)
        }
        if spellMode == .on {
            let packed = SpellTransform.apply(text, mode: .on)
            if capitalizeNextWord {
                capitalizeNextWord = false
                return (CapsTransform.capitalizeFirstWord(packed), true)
            }
            return (packed, true)
        }
        // Sticky caps first, then one-shot cap next on first word (overrides noCaps).
        var shaped = CapsTransform.apply(text, mode: capsMode)
        if capitalizeNextWord {
            shaped = CapsTransform.capitalizeFirstWord(shaped)
            capitalizeNextWord = false
        }
        return (shaped, false)
    }

    /// Arm multi-step replace; text stays until the next content phrase arrives.
    private func performArmReplace() {
        guard ReplaceDecision.canArm(hasLastPhrase: editStack.canUndo) else { return }
        awaitingReplace = true
    }

    /// Single-utterance "replace X with Y": last case-insensitive occurrence.
    /// Dual of PhraseReplaceDecision / specs/ReplacePhrase.tla.
    private func performReplacePhrase(
        target: String,
        replacement: String,
        typesIncrementally: Bool
    ) {
        guard let match = PhraseReplaceDecision.findLastRange(target: target, in: transcribedText),
              let newText = SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: transcribedText,
                start: match.start,
                length: match.length,
                replacement: replacement
              ) else {
            return
        }
        if typesIncrementally {
            moveToSessionOffset(match.start)
            textInserter.selectForward(count: match.length)
            textInserter.typeText(replacement)
        }
        applyPhraseEditResult(
            newText: newText,
            matchStart: match.start,
            matchLength: match.length,
            stackPush: replacement.isEmpty ? nil : replacement
        )
    }

    /// Single-utterance "delete X": last occurrence (with adjacent space absorb).
    /// Dual of PhraseReplaceDecision / specs/DeletePhrase.tla.
    private func performDeletePhrase(target: String, typesIncrementally: Bool) {
        guard let match = PhraseReplaceDecision.findLastDeletableRange(
            target: target,
            in: transcribedText
        ),
              let newText = SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: transcribedText,
                start: match.start,
                length: match.length,
                replacement: ""
              ) else {
            return
        }
        if typesIncrementally {
            moveToSessionOffset(match.start)
            textInserter.selectForward(count: match.length)
            textInserter.deleteBackward(count: 1)
        }
        applyPhraseEditResult(
            newText: newText,
            matchStart: match.start,
            matchLength: match.length,
            stackPush: nil
        )
    }

    /// Shared stack/nav update after phrase replace or delete.
    private func applyPhraseEditResult(
        newText: String,
        matchStart: Int,
        matchLength: Int,
        stackPush: String?
    ) {
        if SelectionCommitDecision.isTrailing(
            start: matchStart,
            length: matchLength,
            bufferCount: transcribedText.count
        ) {
            let suffix = String(transcribedText.suffix(matchLength))
            if !editStack.dropTrailingSuffix(suffix) {
                editStack.clear()
            }
        } else {
            editStack.clear()
        }
        transcribedText = newText
        if let push = stackPush, !push.isEmpty {
            editStack.push(push)
        }
        sessionSelection = nil
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
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

    /// Dragon "Tab <n> times": insert N tab characters (one stack delta).
    /// Dual of specs/TabN.tla.
    private func performPressTab(count: Int = 1, typesIncrementally: Bool) {
        let n = TabDecision.clampCount(count)
        let s = String(repeating: "\t", count: n)
        performKeyInsert(s, typesIncrementally: typesIncrementally)
    }

    /// Dragon "press enter N times": insert N newlines (one stack delta).
    /// Dual of specs/EnterN.tla. Host types via TextInserter steps (Return keys).
    private func performPressEnter(count: Int = 1, typesIncrementally: Bool) {
        let n = EnterDecision.clampCount(count)
        let s = String(repeating: "\n", count: n)
        performKeyInsert(s, typesIncrementally: typesIncrementally)
    }

    /// Dragon "press space N times": insert N spaces (one stack delta).
    /// Dual of specs/SpaceN.tla.
    private func performPressSpace(count: Int = 1, typesIncrementally: Bool) {
        let n = SpaceDecision.clampCount(count)
        let s = String(repeating: " ", count: n)
        performKeyInsert(s, typesIncrementally: typesIncrementally)
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

    /// Duplicate last phrase (prefer EditStack top), else whole session buffer.
    /// Copies to clipboard, appends to buffer + stack; types only when incremental.
    private func performDuplicateThat(typesIncrementally: Bool) {
        let text: String
        if let delta = editStack.lastDelta, !delta.isEmpty {
            text = delta
        } else {
            guard !transcribedText.isEmpty else { return }
            text = transcribedText
        }
        textInserter.copyToClipboard(text)
        transcribedText += text
        editStack.push(text)
        if typesIncrementally {
            textInserter.typeText(text)
        }
        lastCommittedNormalized = ""
    }

    /// Undo the last N typed segments (Dragon "scratch that" / "scratch that N times").
    /// Uses EditStack multi-level undo; pure plan dual of specs/ScratchThatN.tla.
    private func performScratchThat(count: Int = 1, typesIncrementally: Bool) {
        let n = ScratchThatDecision.clampCount(count)
        let lengths = editStack.undoItems.map(\.count)
        let plan = ScratchThatDecision.plan(undoLengthsOldestFirst: lengths, count: n)
        guard plan.steps > 0 else { return }

        var totalRemove = 0
        for _ in 0..<plan.steps {
            guard let delta = editStack.undo() else { break }
            let remove = min(delta.count, transcribedText.count)
            if remove > 0 {
                transcribedText = String(transcribedText.dropLast(remove))
                totalRemove += remove
            }
        }
        if typesIncrementally, totalRemove > 0 {
            textInserter.deleteBackward(count: totalRemove)
        }
        lastCommittedNormalized = ""
    }

    /// Redo the last N scratched segments ("redo that" / "redo that N times").
    /// Dual of specs/RedoThatN.tla — reuses ScratchThatDecision peel plan.
    private func performRedoThat(count: Int = 1, typesIncrementally: Bool) {
        let n = ScratchThatDecision.clampCount(count)
        let lengths = editStack.redoItems.map(\.count)
        let plan = ScratchThatDecision.plan(undoLengthsOldestFirst: lengths, count: n)
        guard plan.steps > 0 else { return }

        var typed = ""
        for _ in 0..<plan.steps {
            guard let delta = editStack.redo() else { break }
            transcribedText += delta
            typed += delta
        }
        if typesIncrementally, !typed.isEmpty {
            textInserter.typeText(typed)
        }
        lastCommittedNormalized = ""
    }

    /// Delete a trailing selection (sentence / paragraph / line) from the
    /// session transcript. `selected` must be a suffix of `transcribedText`
    /// (as returned by `TranscriptSelection`); if not exact, drop only when
    /// the buffer ends with that suffix after best-effort match.
    /// Empty selection + trailing newlines: peel `\n\n` (para) or `\n` (line)
    /// so "delete last line" on `"Hello.\n"` is not a no-op.
    /// Stack-aware via `dropTrailingSuffix` so "redo that" can restore.
    private func performDeleteTrailingSelection(selected: String, typesIncrementally: Bool) {
        let resolved: String
        if !selected.isEmpty {
            resolved = selected
        } else if transcribedText.hasSuffix("\n\n") {
            resolved = "\n\n"
        } else if transcribedText.hasSuffix("\n") {
            resolved = "\n"
        } else {
            return
        }

        let removed: String
        if transcribedText.hasSuffix(resolved) {
            removed = resolved
        } else if let range = transcribedText.range(of: resolved, options: .backwards),
                  range.upperBound == transcribedText.endIndex {
            removed = String(transcribedText[range])
        } else {
            return
        }

        transcribedText = String(transcribedText.dropLast(removed.count))
        if typesIncrementally {
            textInserter.deleteBackward(count: removed.count)
        }
        if !editStack.dropTrailingSuffix(removed) {
            editStack.clear()
        }
        lastCommittedNormalized = ""
    }

    /// Delete the last whitespace-delimited word from the session transcript.
    /// Prefers adjusting EditStack so prior segments remain undoable and
    /// "redo that" can restore the deleted word.
    private func performDeleteLastWord(typesIncrementally: Bool) {
        performDeleteLastWords(count: 1, typesIncrementally: typesIncrementally)
    }

    /// Delete the last `count` whitespace-delimited words (session buffer).
    private func performDeleteLastWords(count: Int, typesIncrementally: Bool) {
        guard count > 0 else { return }
        let original = transcribedText
        for _ in 0..<count {
            guard !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            peelOneTrailingWordFromBuffer()
        }
        let remove = original.count - transcribedText.count
        guard remove > 0 else { return }
        if typesIncrementally {
            textInserter.deleteBackward(count: remove)
        }
        let removed = String(original.suffix(remove))
        if !editStack.dropTrailingSuffix(removed) {
            editStack.clear()
        }
        lastCommittedNormalized = ""
    }

    /// Peel one trailing word (+ leading space) from `transcribedText` only.
    private func peelOneTrailingWordFromBuffer() {
        var buffer = transcribedText
        while buffer.last?.isWhitespace == true {
            buffer.removeLast()
        }
        guard let lastSpace = buffer.lastIndex(where: { $0.isWhitespace }) else {
            transcribedText = ""
            return
        }
        let wordStart = buffer.index(after: lastSpace)
        var start = wordStart
        if start > transcribedText.startIndex {
            let before = transcribedText.index(before: start)
            if transcribedText[before].isWhitespace {
                start = before
            }
        }
        transcribedText = String(transcribedText[..<start])
    }

    /// Delete the first sentence (and separator before the second). Resets nav.
    private func performDeleteFirstSentence(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        if ranges.count == 1 {
            performClearAll(typesIncrementally: typesIncrementally)
            return
        }
        let keepStart = ranges[1].start
        performDeletePrefix(through: keepStart, typesIncrementally: typesIncrementally)
    }

    /// Delete the first paragraph (and separator before the second). Resets nav.
    private func performDeleteFirstParagraph(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        if ranges.count == 1 {
            performClearAll(typesIncrementally: typesIncrementally)
            return
        }
        let keepStart = ranges[1].start
        performDeletePrefix(through: keepStart, typesIncrementally: typesIncrementally)
    }

    /// Delete the first line (and newline before the second). Resets nav.
    private func performDeleteFirstLine(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        guard !ranges.isEmpty else { return }
        if ranges.count == 1 {
            performClearAll(typesIncrementally: typesIncrementally)
            return
        }
        let keepStart = ranges[1].start
        performDeletePrefix(through: keepStart, typesIncrementally: typesIncrementally)
    }

    /// Remove buffer prefix `[0, through)` and type-delete when incremental.
    private func performDeletePrefix(through keepStart: Int, typesIncrementally: Bool) {
        let text = transcribedText
        guard keepStart > 0, keepStart <= text.count else { return }
        let keepIdx = text.index(text.startIndex, offsetBy: keepStart)
        let newText = String(text[keepIdx...])
        if typesIncrementally {
            // From end: go to start, select prefix, delete.
            textInserter.moveBackward(count: text.count)
            textInserter.selectForward(count: keepStart)
            textInserter.deleteBackward(count: 1)
        }
        transcribedText = newText
        editStack.clear()
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
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
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Select the last typed phrase (EditStack top delta). Buffer unchanged.
    /// Requires focus in target app (same as deleteBackward).
    private func performSelectThat(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        guard let delta = editStack.lastDelta, !delta.isEmpty else { return }
        guard transcribedText.hasSuffix(delta) else { return }
        armSessionSelection(start: transcribedText.count - delta.count, length: delta.count)
        textInserter.selectBackward(count: delta.count)
    }

    /// Select last occurrence of `target` in session buffer; arm type-over.
    /// Dual of PhraseReplaceDecision / specs/SelectPhrase.tla. Buffer unchanged.
    private func performSelectPhrase(target: String, typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        guard let match = PhraseReplaceDecision.findLastRange(
            target: target,
            in: transcribedText
        ) else {
            return
        }
        armSessionSelection(start: match.start, length: match.length)
        moveToSessionOffset(match.start)
        textInserter.selectForward(count: match.length)
    }

    /// Dragon "resume with X": keep through last X, delete everything after, append next.
    /// Dual of ResumeWithDecision / specs/ResumeWith.tla.
    private func performResumeWith(target: String, typesIncrementally: Bool) {
        guard let result = ResumeWithDecision.truncateAfterLastMatch(
            target: target,
            buffer: transcribedText
        ) else { return }
        if result.deletedCount > 0 {
            if typesIncrementally {
                // Host caret is typically at end after dictation.
                textInserter.deleteBackward(count: result.deletedCount)
            }
            // Peel stack when deleted suffix is trailing (it always is).
            let removed = String(transcribedText.suffix(result.deletedCount))
            if !editStack.dropTrailingSuffix(removed) {
                editStack.clear()
            }
        }
        transcribedText = result.buffer
        sessionSelection = nil
        // Caret at end of kept text → append mode for next content.
        sessionCaret = nil
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
        wordNavIndex = nil
        wordSelectionActive = false
        awaitingReplace = false
    }

    /// Move caret to start (or end if `after`) of last occurrence of `target`.
    /// Sets `sessionCaret` so next content inserts mid-buffer (not always append).
    /// Spoken: go to/after X, insert before/after X (Dragon). Dual of specs/GoToPhrase.tla.
    private func performGoToPhrase(target: String, after: Bool, typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        guard let match = PhraseReplaceDecision.findLastRange(
            target: target,
            in: transcribedText
        ) else {
            return
        }
        // Clear selection arm; caret drives insert (not type-over replace).
        sessionSelection = nil
        textInserter.clearSelection()
        let offset = after ? match.start + match.length : match.start
        moveToSessionOffset(offset)
        sessionCaret = offset < transcribedText.count ? offset : nil
        // Reset progressive unit nav — caret is no longer at a known unit edge.
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Select last phrase (when available) then apply bold/italic/underline.
    /// If nothing to select, still format current app selection.
    /// Always collapses selection after format so next typing does not overwrite.
    private func performFormatThat(_ style: TextFormatStyle, typesIncrementally: Bool) {
        if typesIncrementally, let delta = editStack.lastDelta, !delta.isEmpty {
            textInserter.selectBackward(count: delta.count)
        }
        textInserter.applyFormat(style)
        textInserter.clearSelection()
        sessionSelection = nil
    }

    /// Collapse the current selection (spoken "unselect that"). Buffer unchanged.
    private func performUnselectThat() {
        textInserter.clearSelection()
        sessionSelection = nil
    }

    /// Select last phrase, cut (⌘X), drop buffer delta without re-deleting.
    /// Cut already removes text from the app; buffer tracks session only.
    private func performCutThat(typesIncrementally: Bool) {
        guard let delta = editStack.lastDelta, !delta.isEmpty else {
            // No stack delta — still try cut on whatever the app has selected.
            if typesIncrementally {
                textInserter.cutSelection()
            }
            return
        }
        if typesIncrementally {
            textInserter.selectBackward(count: delta.count)
            textInserter.cutSelection()
        }
        // Scratch-like buffer update; never deleteBackward (cut already removed).
        if let removed = editStack.undo() {
            let remove = min(removed.count, transcribedText.count)
            if remove > 0 {
                transcribedText = String(transcribedText.dropLast(remove))
            }
            lastCommittedNormalized = ""
        }
    }

    /// Enter spell mode and select last phrase (Dragon-style "spell that").
    /// Does not delete text — next spoken letters replace selection when typed.
    private func performSpellThat(typesIncrementally: Bool) {
        spellMode = .on
        performSelectThat(typesIncrementally: typesIncrementally)
    }

    /// Press Backspace once. Keyboard-only; session buffer / edit stack unchanged.
    /// Dragon "Backspace <n>": press host Backspace N times. Keyboard-only.
    /// Dual of specs/BackspaceN.tla (host peel; session buffer unchanged).
    private func performPressBackspace(count: Int = 1) {
        let n = BackspaceDecision.clampCount(count)
        textInserter.deleteBackward(count: n)
    }

    /// Press Escape once. Keyboard-only; buffer / stack unchanged.
    /// Does not cancel the Chirp session (physical ESC hotkey still does).
    private func performPressEscape() {
        textInserter.pressEscape()
    }

    /// System undo (⌘Z). Keyboard-only; buffer / edit stack unchanged.
    /// Date stamp via instance clock (not process-global InsertStamp providers).
    private func stampDate() -> String {
        InsertStamp.formatDate(nowProvider(), timeZone: timeZoneProvider())
    }

    /// Time stamp via instance clock (not process-global InsertStamp providers).
    private func stampTime() -> String {
        InsertStamp.formatTime(nowProvider(), timeZone: timeZoneProvider())
    }

    private func performPressUndo() {
        textInserter.pressUndo()
    }

    /// System redo (⌘⇧Z). Keyboard-only; buffer / edit stack unchanged.
    private func performPressRedo() {
        textInserter.pressRedo()
    }

    /// Press Forward Delete once. Keyboard-only; buffer / stack unchanged.
    /// Forward Delete N times (right-of-caret). Dual of specs/ForwardDeleteN.tla.
    private func performPressForwardDelete(count: Int = 1) {
        let n = BackspaceDecision.clampCount(count)
        for _ in 0..<n {
            textInserter.pressForwardDelete()
        }
    }

    /// Select one word. Previous: trailing then progressive step-back via wordNavIndex.
    /// Next: progressive wordNavIndex (or at/after sessionCaret). Dual: WordCursor.tla.
    private func performSelectWord(direction: MoveDirection, typesIncrementally: Bool) {
        performSelectWords(direction: direction, count: 1, typesIncrementally: typesIncrementally)
    }

    /// Select N words. Previous: trailing from end, then progressive step-back via wordNavIndex.
    /// Next: progressive wordNavIndex (or first word at/after sessionCaret). Dual: WordCursor.tla.
    private func performSelectWords(direction: MoveDirection, count: Int, typesIncrementally: Bool) {
        guard count > 0 else { return }
        if direction == .left, typesIncrementally {
            let words = TranscriptSelection.wordRanges(transcribedText)
            if !words.isEmpty {
                // Further previous: step back from progressive index (content-only span).
                if let idx = wordNavIndex, idx > 0 {
                    let endIdx = idx - 1
                    let startIdx = max(0, endIdx - count + 1)
                    let start = words[startIdx].start
                    let end = words[endIdx].end
                    let length = end - start
                    guard length > 0 else { return }
                    armSessionSelection(start: start, length: length)
                    moveToSessionOffset(start)
                    textInserter.selectForward(count: length)
                    wordNavIndex = startIdx
                    wordSelectionActive = true
                    return
                }
                // First previous (or no walk yet): trailing last N words.
                if wordNavIndex == nil,
                   !TranscriptSelection.lastWords(transcribedText, count: count).isEmpty {
                    performSelectLastWords(count: count, typesIncrementally: true)
                    return
                }
                // At first word (index 0): no-op (mirror sentence previous).
                if wordNavIndex == 0 {
                    return
                }
            }
        }
        if direction == .right, typesIncrementally {
            let words = TranscriptSelection.wordRanges(transcribedText)
            if !words.isEmpty {
                let startIdx: Int?
                if let idx = wordNavIndex {
                    let next = idx + 1
                    startIdx = next < words.count ? next : nil
                } else if let range = TranscriptSelection.nextWordsRange(
                    transcribedText,
                    caret: sessionCaret,
                    count: 1
                ) {
                    startIdx = words.firstIndex(where: { $0.start == range.start })
                } else {
                    startIdx = nil
                }
                if let startIdx {
                    let endIdx = min(startIdx + count - 1, words.count - 1)
                    let start = words[startIdx].start
                    let end = words[endIdx].end
                    let length = end - start
                    guard length > 0 else { return }
                    // armSessionSelection clears sessionCaret; wordNavIndex survives.
                    armSessionSelection(start: start, length: length)
                    moveToSessionOffset(start)
                    textInserter.selectForward(count: length)
                    wordNavIndex = endIdx
                    wordSelectionActive = true
                    return
                }
            }
        }
        for _ in 0..<count {
            textInserter.selectWord(direction: direction)
        }
    }

    /// Delete one word via select then backspace. Buffer unchanged — caret-relative.
    private func performDeleteWord(direction: MoveDirection) {
        textInserter.deleteWord(direction: direction)
    }

    /// Delete N words in direction (select × N then backspace). Keyboard-only.
    private func performDeleteWords(direction: MoveDirection, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            textInserter.selectWord(direction: direction)
        }
        textInserter.deleteBackward(count: 1)
    }

    /// Select N characters left (previous) or right (next). Keyboard-only.
    private func performSelectCharacters(direction: MoveDirection, count: Int) {
        guard count > 0 else { return }
        if direction == .left {
            textInserter.selectBackward(count: count)
        } else {
            textInserter.selectForward(count: count)
        }
    }

    /// Delete previous N characters from session buffer (+ keyboard when incremental).
    private func performDeletePreviousCharacters(count: Int, typesIncrementally: Bool) {
        guard count > 0 else { return }
        let n = min(count, transcribedText.count)
        guard n > 0 else { return }
        let removed = String(transcribedText.suffix(n))
        transcribedText = String(transcribedText.dropLast(n))
        if typesIncrementally {
            textInserter.deleteBackward(count: n)
        }
        if !editStack.dropTrailingSuffix(removed) {
            editStack.clear()
        }
        lastCommittedNormalized = ""
    }

    /// Delete next N characters (select forward then backspace). Keyboard-only.
    private func performDeleteNextCharacters(count: Int) {
        guard count > 0 else { return }
        textInserter.selectForward(count: count)
        textInserter.deleteBackward(count: 1)
    }

    /// Select the last whitespace-delimited word. Buffer unchanged.
    private func performSelectLastWord(typesIncrementally: Bool) {
        performSelectLastWords(count: 1, typesIncrementally: typesIncrementally)
    }

    /// Select last N whitespace-delimited words (session trailing). Buffer unchanged.
    private func performSelectLastWords(count: Int, typesIncrementally: Bool) {
        guard typesIncrementally, count > 0 else { return }
        let selected = TranscriptSelection.lastWords(transcribedText, count: count)
        guard !selected.isEmpty else { return }
        armSessionSelection(start: transcribedText.count - selected.count, length: selected.count)
        textInserter.selectBackward(count: selected.count)
        let words = TranscriptSelection.wordRanges(transcribedText)
        if !words.isEmpty {
            let n = min(count, words.count)
            wordNavIndex = words.count - n
            wordSelectionActive = true
        }
    }

    /// Select the last sentence. Buffer unchanged.
    private func performSelectLastSentence(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        let last = ranges.count - 1
        let selected = TranscriptSelection.lastSentence(text)
        guard !selected.isEmpty else { return }
        // Prefer trailing selectBackward when caret model is end (index nil).
        if sentenceNavIndex == nil && !sentenceSelectionActive {
            armSessionSelection(start: text.count - selected.count, length: selected.count)
            textInserter.selectBackward(count: selected.count)
        } else {
            let range = ranges[last]
            armSessionSelection(start: range.start, length: range.end - range.start)
            moveToSessionOffset(range.start)
            textInserter.selectForward(count: range.end - range.start)
        }
        sentenceNavIndex = last
        sentenceSelectionActive = true
    }

    /// Select the first sentence. Moves to first sentence start, selects forward.
    /// Sets `sentenceNavIndex` so further select/move next are progressive.
    private func performSelectFirstSentence(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        let range = ranges[0]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToSessionOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        sentenceNavIndex = 0
        sentenceSelectionActive = true
    }

    /// Select the next sentence (progressive). From end: second sentence; further
    /// calls advance. Collapses prior selection first. Buffer unchanged.
    private func performSelectNextSentence(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        let next: Int
        if sentenceNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = sentenceNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToSessionOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        sentenceNavIndex = next
        sentenceSelectionActive = true
    }

    /// Select previous sentence (progressive). From end: last; further step back.
    private func performSelectPreviousSentence(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if sentenceNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = sentenceNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToSessionOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        sentenceNavIndex = next
        sentenceSelectionActive = true
    }

    private enum TrailingUnit {
        case sentence, paragraph, line
    }

    /// Delete last N sentences (trailing peel). N ≥ 1.
    private func performDeleteLastSentences(count: Int, typesIncrementally: Bool) {
        performDeleteLastUnits(kind: .sentence, count: count, typesIncrementally: typesIncrementally)
    }

    /// Delete last N paragraphs (trailing peel). N ≥ 1.
    private func performDeleteLastParagraphs(count: Int, typesIncrementally: Bool) {
        performDeleteLastUnits(kind: .paragraph, count: count, typesIncrementally: typesIncrementally)
    }

    /// Delete last N lines (trailing peel). N ≥ 1.
    private func performDeleteLastLines(count: Int, typesIncrementally: Bool) {
        performDeleteLastUnits(kind: .line, count: count, typesIncrementally: typesIncrementally)
    }

    /// Peel last N trailing units in one cut (range-based, not repeated last-segment).
    /// Avoids blank-separator peels eating N budget without removing content units.
    private func performDeleteLastUnits(kind: TrailingUnit, count: Int, typesIncrementally: Bool) {
        guard count > 0 else { return }
        let text = transcribedText
        let ranges: [TranscriptSelection.SentenceRange]
        switch kind {
        case .sentence: ranges = TranscriptSelection.sentenceRanges(text)
        case .paragraph: ranges = TranscriptSelection.paragraphRanges(text)
        case .line: ranges = TranscriptSelection.lineRanges(text)
        }
        guard !ranges.isEmpty else { return }
        let n = min(count, ranges.count)
        let startIdx = ranges.count - n
        // Keep through end of unit before the first deleted one (includes no trailing sep).
        // Cut from prior unit end so the separator before the deleted span is removed.
        let cutStart = startIdx == 0 ? 0 : ranges[startIdx - 1].end
        guard cutStart < text.count else { return }
        let newText = String(text.prefix(cutStart))
        let remove = text.count - cutStart
        transcribedText = newText
        if typesIncrementally, remove > 0 {
            textInserter.deleteBackward(count: remove)
        }
        let removed = String(text.suffix(remove))
        if !editStack.dropTrailingSuffix(removed) {
            editStack.clear()
        }
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Select last N trailing sentences/paragraphs/lines via selectBackward.
    private func performSelectLastUnits(kind: TrailingUnit, count: Int, typesIncrementally: Bool) {
        guard typesIncrementally, count > 0 else { return }
        let text = transcribedText
        let ranges = unitRanges(kind, text)
        guard !ranges.isEmpty else { return }
        let n = min(count, ranges.count)
        let startIdx = ranges.count - n
        let start = ranges[startIdx].start
        let fromEnd = text.count - start
        guard fromEnd > 0 else { return }
        armSessionSelection(start: start, length: fromEnd)
        textInserter.selectBackward(count: fromEnd)
        setUnitNav(kind: kind, index: startIdx, selectionActive: true)
    }

    /// Select next N units (session-relative). From end: starts at second unit.
    /// Further progressive: starts after current nav index.
    private func performSelectNextUnits(kind: TrailingUnit, count: Int, typesIncrementally: Bool) {
        guard typesIncrementally, count > 0 else { return }
        let text = transcribedText
        let ranges = unitRanges(kind, text)
        guard ranges.count >= 2 else { return }
        let startIdx: Int
        if let idx = unitNavIndex(kind) {
            startIdx = idx + 1
        } else {
            startIdx = 1
        }
        guard startIdx < ranges.count else { return }
        let endIdx = min(startIdx + count, ranges.count) // exclusive
        let spanStart = ranges[startIdx].start
        let spanEnd = ranges[endIdx - 1].end
        armSessionSelection(start: spanStart, length: spanEnd - spanStart)
        moveToUnitOffset(kind: kind, offset: spanStart)
        textInserter.selectForward(count: spanEnd - spanStart)
        setUnitNav(kind: kind, index: endIdx - 1, selectionActive: true)
    }

    /// Delete next N units (session-relative). From end: starts at second unit.
    private func performDeleteNextUnits(kind: TrailingUnit, count: Int, typesIncrementally: Bool) {
        guard count > 0 else { return }
        let text = transcribedText
        let ranges = unitRanges(kind, text)
        guard ranges.count >= 2 else { return }
        let startIdx: Int
        if let idx = unitNavIndex(kind) {
            startIdx = idx + 1
        } else {
            startIdx = 1
        }
        guard startIdx < ranges.count else { return }
        let endIdx = min(startIdx + count, ranges.count) // exclusive
        // Cut from end of prior unit through end of last deleted unit.
        let cutStart = ranges[startIdx - 1].end
        let cutEnd = ranges[endIdx - 1].end
        guard cutStart < cutEnd, cutEnd <= text.count else { return }
        let keepPrefix = String(text.prefix(cutStart))
        let keepSuffix = String(text.dropFirst(cutEnd))
        let newText = keepPrefix + keepSuffix
        let remove = cutEnd - cutStart
        if typesIncrementally, remove > 0 {
            moveToUnitOffset(kind: kind, offset: cutStart)
            textInserter.selectForward(count: remove)
            textInserter.deleteBackward(count: 1)
        }
        transcribedText = newText
        editStack.clear()
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    private func unitRanges(_ kind: TrailingUnit, _ text: String) -> [TranscriptSelection.SentenceRange] {
        switch kind {
        case .sentence: return TranscriptSelection.sentenceRanges(text)
        case .paragraph: return TranscriptSelection.paragraphRanges(text)
        case .line: return TranscriptSelection.lineRanges(text)
        }
    }

    private func unitNavIndex(_ kind: TrailingUnit) -> Int? {
        switch kind {
        case .sentence: return sentenceNavIndex
        case .paragraph: return paragraphNavIndex
        case .line: return lineNavIndex
        }
    }

    private func setUnitNav(kind: TrailingUnit, index: Int, selectionActive: Bool) {
        switch kind {
        case .sentence:
            sentenceNavIndex = index
            sentenceSelectionActive = selectionActive
        case .paragraph:
            paragraphNavIndex = index
            paragraphSelectionActive = selectionActive
        case .line:
            lineNavIndex = index
            lineSelectionActive = selectionActive
        }
    }

    private func moveToUnitOffset(kind: TrailingUnit, offset: Int) {
        switch kind {
        case .sentence: moveToSessionOffset(offset)
        case .paragraph: moveToParagraphOffset(offset)
        case .line: moveToLineOffset(offset)
        }
    }

    /// Select previous paragraph (progressive). From end: last; further step back.
    private func performSelectPreviousParagraph(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if paragraphNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = paragraphNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToParagraphOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        paragraphNavIndex = next
        paragraphSelectionActive = true
    }

    /// Select previous line (progressive). From end: last; further step back.
    private func performSelectPreviousLine(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if lineNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = lineNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToLineOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        lineNavIndex = next
        lineSelectionActive = true
    }

    /// Delete the next sentence (progressive). From end: second sentence; further
    /// calls use `sentenceNavIndex`. When target is trailing, stack-aware peel;
    /// else middle string surgery (stack cleared). Resets nav index.
    private func performDeleteNextSentence(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        let target: Int
        if sentenceNavIndex == nil {
            guard ranges.count >= 2 else { return }
            target = 1
        } else {
            guard let idx = sentenceNavIndex, idx + 1 < ranges.count else { return }
            target = idx + 1
        }

        let range = ranges[target]
        let remainderAfter = String(text.dropFirst(range.end))
        let isTrailing = remainderAfter.allSatisfy(\.isWhitespace)

        if isTrailing {
            // Target is last: peel trailing sentence (includes leading separator space).
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastSentence(text),
                typesIncrementally: typesIncrementally
            )
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
            return
        }

        // Middle delete: keep through prior sentence end + remainder after target.
        let priorEnd = ranges[target - 1].end
        let keepEndIdx = text.index(text.startIndex, offsetBy: priorEnd)
        let afterIdx = text.index(text.startIndex, offsetBy: range.end)
        let newText = String(text[..<keepEndIdx]) + String(text[afterIdx...])
        let gapAndTargetCount = range.end - priorEnd

        if typesIncrementally, gapAndTargetCount > 0 {
            // Land at end of prior sentence, select gap+target, delete selection.
            moveToSessionOffset(priorEnd)
            textInserter.selectForward(count: gapAndTargetCount)
            textInserter.deleteBackward(count: 1)
        }

        transcribedText = newText
        editStack.clear()
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Select the last paragraph. Buffer unchanged.
    private func performSelectLastParagraph(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        let last = ranges.count - 1
        let selected = TranscriptSelection.lastParagraph(text)
        guard !selected.isEmpty else { return }
        if paragraphNavIndex == nil && !paragraphSelectionActive {
            armSessionSelection(start: text.count - selected.count, length: selected.count)
            textInserter.selectBackward(count: selected.count)
        } else {
            let range = ranges[last]
            armSessionSelection(start: range.start, length: range.end - range.start)
            moveToParagraphOffset(range.start)
            textInserter.selectForward(count: range.end - range.start)
        }
        paragraphNavIndex = last
        paragraphSelectionActive = true
    }

    /// Select the first paragraph. Sets `paragraphNavIndex` for progressive next.
    private func performSelectFirstParagraph(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        let range = ranges[0]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToParagraphOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        paragraphNavIndex = 0
        paragraphSelectionActive = true
    }

    /// Select the next paragraph (progressive). From end: second paragraph;
    /// further calls advance (3rd, 4th, …). Collapses prior selection first.
    /// Buffer unchanged. Dual of specs/ParagraphCursor.tla.
    private func performSelectNextParagraph(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        let next: Int
        if paragraphNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = paragraphNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToParagraphOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        paragraphNavIndex = next
        paragraphSelectionActive = true
    }

    /// Delete the next paragraph (progressive). From end: second paragraph;
    /// further calls use `paragraphNavIndex`. Trailing → stack-aware peel;
    /// middle → string surgery (stack cleared). Resets nav indices.
    private func performDeleteNextParagraph(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        let target: Int
        if paragraphNavIndex == nil {
            guard ranges.count >= 2 else { return }
            target = 1
        } else {
            guard let idx = paragraphNavIndex, idx + 1 < ranges.count else { return }
            target = idx + 1
        }

        let range = ranges[target]
        let remainderAfter = String(text.dropFirst(range.end))
        let isTrailing = remainderAfter.allSatisfy(\.isWhitespace)

        if isTrailing {
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastParagraph(text),
                typesIncrementally: typesIncrementally
            )
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
            return
        }

        // Middle delete: keep through prior paragraph end + remainder after target.
        // Include separator between prior and target in the deleted gap.
        let priorEnd = ranges[target - 1].end
        let keepEndIdx = text.index(text.startIndex, offsetBy: priorEnd)
        let afterIdx = text.index(text.startIndex, offsetBy: range.end)
        let newText = String(text[..<keepEndIdx]) + String(text[afterIdx...])
        let gapAndTargetCount = range.end - priorEnd

        if typesIncrementally, gapAndTargetCount > 0 {
            moveToParagraphOffset(priorEnd)
            textInserter.selectForward(count: gapAndTargetCount)
            textInserter.deleteBackward(count: 1)
        }

        transcribedText = newText
        editStack.clear()
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Select the last line. Buffer unchanged.
    private func performSelectLastLine(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        guard !ranges.isEmpty else { return }
        let selected = TranscriptSelection.lastLine(text)
        guard !selected.isEmpty else { return }
        if lineNavIndex == nil && !lineSelectionActive {
            armSessionSelection(start: text.count - selected.count, length: selected.count)
            textInserter.selectBackward(count: selected.count)
        } else {
            let last = ranges.count - 1
            let range = ranges[last]
            armSessionSelection(start: range.start, length: range.end - range.start)
            moveToLineOffset(range.start)
            textInserter.selectForward(count: range.end - range.start)
        }
        lineNavIndex = ranges.count - 1
        lineSelectionActive = true
    }

    /// Select the first line. Sets `lineNavIndex` for progressive next.
    private func performSelectFirstLine(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        guard !ranges.isEmpty else { return }
        let range = ranges[0]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToLineOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        lineNavIndex = 0
        lineSelectionActive = true
    }

    /// Select the next line (progressive). From end: second line; further calls advance.
    private func performSelectNextLine(typesIncrementally: Bool) {
        guard typesIncrementally else { return }
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        let next: Int
        if lineNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = lineNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let range = ranges[next]
        armSessionSelection(start: range.start, length: range.end - range.start)
        moveToLineOffset(range.start)
        textInserter.selectForward(count: range.end - range.start)
        lineNavIndex = next
        lineSelectionActive = true
    }

    /// Delete the next line (progressive). From end: second line.
    /// Trailing → stack-aware peel; middle → string surgery.
    private func performDeleteNextLine(typesIncrementally: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        let target: Int
        if lineNavIndex == nil {
            guard ranges.count >= 2 else { return }
            target = 1
        } else {
            guard let idx = lineNavIndex, idx + 1 < ranges.count else { return }
            target = idx + 1
        }

        let range = ranges[target]
        let remainderAfter = String(text.dropFirst(range.end))
        let isTrailing = remainderAfter.allSatisfy(\.isWhitespace)

        if isTrailing {
            performDeleteTrailingSelection(
                selected: TranscriptSelection.lastLine(text),
                typesIncrementally: typesIncrementally
            )
            sentenceNavIndex = nil
            sentenceSelectionActive = false
            paragraphNavIndex = nil
            paragraphSelectionActive = false
            lineNavIndex = nil
            lineSelectionActive = false
            return
        }

        // Middle: keep through prior line end; drop separator+target.
        let priorEnd = ranges[target - 1].end
        let keepEndIdx = text.index(text.startIndex, offsetBy: priorEnd)
        let afterIdx = text.index(text.startIndex, offsetBy: range.end)
        // Include the newline between prior and target in the deleted span.
        let newText = String(text[..<keepEndIdx]) + String(text[afterIdx...])
        let gapAndTargetCount = range.end - priorEnd

        if typesIncrementally, gapAndTargetCount > 0 {
            moveToLineOffset(priorEnd)
            textInserter.selectForward(count: gapAndTargetCount)
            textInserter.deleteBackward(count: 1)
        }

        transcribedText = newText
        editStack.clear()
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Move caret to a Character offset within the session buffer (line nav).
    /// Host "from" dual of SessionCaretDecision.hostFrom / specs/HostCaret.tla.
    private func moveToLineOffset(_ offset: Int) {
        let text = transcribedText
        var unitAnchor: Int? = nil
        if let idx = lineNavIndex {
            let ranges = TranscriptSelection.lineRanges(text)
            if ranges.indices.contains(idx) {
                if lineSelectionActive {
                    textInserter.clearSelection()
                    unitAnchor = ranges[idx].end
                    lineSelectionActive = false
                } else {
                    unitAnchor = ranges[idx].start
                }
            }
        }
        let from = SessionCaretDecision.hostFrom(
            bufferCount: text.count,
            sessionCaret: sessionCaret,
            unitAnchor: unitAnchor
        )
        let delta = SessionCaretDecision.moveDelta(from: from, to: offset)
        if delta > 0 { textInserter.moveForward(count: delta) }
        if delta < 0 { textInserter.moveBackward(count: -delta) }
    }

    /// Select all in the focused app (⌘A). Buffer unchanged.
    private func performSelectAll(typesIncrementally: Bool) {
        // ⌘A is useful after non-incremental type as well (text is in the app).
        _ = typesIncrementally
        textInserter.selectAll()
    }

    /// Move cursor one word (⌥← / ⌥→). Buffer unchanged; sets sessionCaret for mid-insert.
    private func performMoveWord(direction: MoveDirection) {
        performMoveWords(direction: direction, count: 1)
    }

    /// Move cursor N words (⌥← / ⌥→ × N). Buffer unchanged; sets sessionCaret.
    /// Dual of TranscriptSelection.offsetAfterWordMove + SessionCaretDecision.
    private func performMoveWords(direction: MoveDirection, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            textInserter.moveWord(direction: direction)
        }
        let to = TranscriptSelection.offsetAfterWordMove(
            transcribedText,
            caret: sessionCaret,
            left: direction == .left,
            count: count
        )
        setSessionCaret(to)
        // Word nav is independent of sentence/paragraph/line progressive indices.
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Move cursor N characters (← / → × N). Buffer unchanged; sets sessionCaret.
    /// Dual of TranscriptSelection.offsetAfterCharacterMove + CharacterCaret.tla.
    private func performMoveCharacters(direction: MoveDirection, count: Int) {
        guard count > 0 else { return }
        if direction == .left {
            textInserter.moveBackward(count: count)
        } else {
            textInserter.moveForward(count: count)
        }
        let to = TranscriptSelection.offsetAfterCharacterMove(
            transcribedText,
            caret: sessionCaret,
            left: direction == .left,
            count: count
        )
        setSessionCaret(to)
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Move cursor N lines (↑ / ↓ × N). Dragon "move down N lines".
    /// Buffer unchanged; sets sessionCaret for mid-insert.
    /// Dual of TranscriptSelection.offsetAfterLineMove + MoveLinesN.tla / LineCaret.tla.
    private func performMoveLine(direction: MoveDirection, count: Int = 1) {
        let n = LineMoveDecision.clampCount(count)
        for _ in 0..<n {
            textInserter.moveLine(direction: direction)
        }
        let to = TranscriptSelection.offsetAfterLineMove(
            transcribedText,
            caret: sessionCaret,
            up: direction == .up,
            count: n
        )
        setSessionCaret(to)
        let ranges = TranscriptSelection.lineRanges(transcribedText)
        if let idx = TranscriptSelection.rangeIndexContaining(to, ranges: ranges) {
            lineNavIndex = idx
        }
        lineSelectionActive = false
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
    }

    /// Select N lines up/down (⇧↑/↓). Keyboard-only; session buffer unchanged.
    /// Dual of specs/SelectLinesN.tla.
    private func performSelectLines(direction: MoveDirection, count: Int = 1) {
        let n = LineMoveDecision.clampCount(count)
        textInserter.selectLine(direction: direction, count: n)
        // Host selection only — do not rewrite session buffer or stack.
        lineSelectionActive = true
        sentenceSelectionActive = false
        paragraphSelectionActive = false
        wordSelectionActive = false
    }

    /// Move up/down N paragraphs to paragraph start (session dual + host ←/→).
    /// Dual of TranscriptSelection.offsetAfterParagraphMove + MoveParagraphsN.tla.
    private func performMoveParagraphs(direction: MoveDirection, count: Int = 1) {
        let n = ParagraphMoveDecision.clampCount(count)
        let to = TranscriptSelection.offsetAfterParagraphMove(
            transcribedText,
            caret: sessionCaret,
            up: direction == .up,
            count: n
        )
        let from = SessionCaretDecision.hostFrom(
            bufferCount: transcribedText.count,
            sessionCaret: sessionCaret,
            unitAnchor: nil
        )
        let delta = SessionCaretDecision.moveDelta(from: from, to: to)
        if delta > 0 { textInserter.moveForward(count: delta) }
        if delta < 0 { textInserter.moveBackward(count: -delta) }
        setSessionCaret(to)
        let ranges = TranscriptSelection.paragraphRanges(transcribedText)
        if let idx = TranscriptSelection.rangeIndexContaining(to, ranges: ranges) {
            paragraphNavIndex = idx
        }
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        wordSelectionActive = false
    }

    /// Progressive "previous line" — dual of LineCursor.tla PrevLine + sessionCaret.
    /// From end: last line start; further calls step back.
    private func performMoveToPreviousLine() {
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if lineNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = lineNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let offset = ranges[next].start
        moveToLineOffset(offset)
        setSessionCaret(offset)
        lineNavIndex = next
        lineSelectionActive = false
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
    }

    /// Progressive "next line" — dual of LineCursor.tla NextLine + sessionCaret.
    /// From end: second line start; further calls advance. Single-line buffer is a no-op.
    private func performMoveToNextLine() {
        let text = transcribedText
        let ranges = TranscriptSelection.lineRanges(text)
        let next: Int
        if lineNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = lineNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let offset = ranges[next].start
        moveToLineOffset(offset)
        setSessionCaret(offset)
        lineNavIndex = next
        lineSelectionActive = false
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
    }

    /// Move cursor to line start (⌘←). Buffer unchanged; sets sessionCaret.
    /// Dual of TranscriptSelection.offsetAtLineStart + LineCaret.tla.
    private func performMoveToLineStart() {
        textInserter.moveToLineStart()
        let to = TranscriptSelection.offsetAtLineStart(transcribedText, caret: sessionCaret)
        setSessionCaret(to)
        clearUnitNavAfterLineOrDocMove()
    }

    /// Move cursor to line end (⌘→). Buffer unchanged; sets sessionCaret.
    /// Dual of TranscriptSelection.offsetAtLineEnd + LineCaret.tla.
    private func performMoveToLineEnd() {
        textInserter.moveToLineEnd()
        let to = TranscriptSelection.offsetAtLineEnd(transcribedText, caret: sessionCaret)
        setSessionCaret(to)
        clearUnitNavAfterLineOrDocMove()
    }

    /// Move cursor to document start (⌘↑). Buffer unchanged; sessionCaret = 0.
    /// Dual of LineCaret.tla DocStart.
    private func performMoveToDocumentStart() {
        textInserter.moveToDocumentStart()
        setSessionCaret(0)
        clearUnitNavAfterLineOrDocMove()
    }

    /// Move cursor to document end (⌘↓). Buffer unchanged; sessionCaret = end (nil).
    /// Dual of LineCaret.tla DocEnd.
    private func performMoveToDocumentEnd() {
        textInserter.moveToDocumentEnd()
        setSessionCaret(transcribedText.count)
        clearUnitNavAfterLineOrDocMove()
    }

    /// Dragon-style "start/end of sentence". Dual of SentenceEdge.tla + sessionCaret.
    private func performMoveToSentenceEdge(start: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        let offset = start
            ? TranscriptSelection.offsetAtSentenceStart(text, caret: sessionCaret)
            : TranscriptSelection.offsetAtSentenceEnd(text, caret: sessionCaret)
        moveToSessionOffset(offset)
        setSessionCaret(offset)
        if let idx = TranscriptSelection.rangeIndexContaining(offset, ranges: ranges) {
            sentenceNavIndex = idx
        }
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Dragon-style "start/end of paragraph". Dual of SentenceEdge.tla + sessionCaret.
    private func performMoveToParagraphEdge(start: Bool) {
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        let offset = start
            ? TranscriptSelection.offsetAtParagraphStart(text, caret: sessionCaret)
            : TranscriptSelection.offsetAtParagraphEnd(text, caret: sessionCaret)
        moveToParagraphOffset(offset)
        setSessionCaret(offset)
        if let idx = TranscriptSelection.rangeIndexContaining(offset, ranges: ranges) {
            paragraphNavIndex = idx
        }
        paragraphSelectionActive = false
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Clear progressive unit nav after line/doc host moves (same as word/char).
    private func clearUnitNavAfterLineOrDocMove() {
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Scroll N pages (Page Up / Page Down × N). Buffer unchanged.
    /// Dual of specs/PageScrollN.tla.
    private func performScrollPage(direction: MoveDirection, count: Int = 1) {
        let n = PageScrollDecision.clampCount(count)
        for _ in 0..<n {
            textInserter.scrollPage(direction: direction)
        }
    }

    /// Move cursor to start of previous sentence (progressive).
    /// From end: last sentence content start; further calls step back.
    private func performMoveToPreviousSentence() {
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if sentenceNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = sentenceNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let offset = ranges[next].start
        moveToSessionOffset(offset)
        setSessionCaret(offset)
        sentenceNavIndex = next
        sentenceSelectionActive = false
    }

    /// Session-relative progressive "next sentence".
    /// From end: jump to second sentence content start (skip whitespace).
    /// Further calls advance to 3rd, 4th, … Single-sentence buffer is a no-op.
    private func performMoveToNextSentence() {
        let text = transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        let next: Int
        if sentenceNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = sentenceNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let offset = ranges[next].start
        moveToSessionOffset(offset)
        setSessionCaret(offset)
        sentenceNavIndex = next
        sentenceSelectionActive = false
    }

    /// Move caret to a Character offset within the session buffer (sentence nav).
    /// Host "from" dual of SessionCaretDecision.hostFrom / specs/HostCaret.tla:
    /// unit nav anchor → sessionCaret → end.
    private func moveToSessionOffset(_ offset: Int) {
        let text = transcribedText
        var unitAnchor: Int? = nil
        if let idx = sentenceNavIndex {
            let ranges = TranscriptSelection.sentenceRanges(text)
            if ranges.indices.contains(idx) {
                if sentenceSelectionActive {
                    // Collapse selection to its trailing edge (end of sentence).
                    textInserter.clearSelection()
                    unitAnchor = ranges[idx].end
                    sentenceSelectionActive = false
                } else {
                    unitAnchor = ranges[idx].start
                }
            }
        }
        let from = SessionCaretDecision.hostFrom(
            bufferCount: text.count,
            sessionCaret: sessionCaret,
            unitAnchor: unitAnchor
        )
        let delta = SessionCaretDecision.moveDelta(from: from, to: offset)
        if delta > 0 { textInserter.moveForward(count: delta) }
        if delta < 0 { textInserter.moveBackward(count: -delta) }
    }

    /// Move cursor to start of previous paragraph (progressive).
    /// From end: last paragraph content start; further calls step back.
    private func performMoveToPreviousParagraph() {
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        guard !ranges.isEmpty else { return }
        let next: Int
        if paragraphNavIndex == nil {
            next = ranges.count - 1
        } else if let idx = paragraphNavIndex, idx > 0 {
            next = idx - 1
        } else {
            return
        }
        let offset = ranges[next].start
        moveToParagraphOffset(offset)
        setSessionCaret(offset)
        paragraphNavIndex = next
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Session-relative progressive "next paragraph" move.
    /// From end: jump to second paragraph start; further calls advance.
    private func performMoveToNextParagraph() {
        let text = transcribedText
        let ranges = TranscriptSelection.paragraphRanges(text)
        let next: Int
        if paragraphNavIndex == nil {
            guard ranges.count >= 2 else { return }
            next = 1
        } else {
            guard let idx = paragraphNavIndex, idx + 1 < ranges.count else { return }
            next = idx + 1
        }
        let offset = ranges[next].start
        moveToParagraphOffset(offset)
        setSessionCaret(offset)
        paragraphNavIndex = next
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
    }

    /// Move caret to a Character offset within the session buffer (paragraph nav).
    /// Host "from" dual of SessionCaretDecision.hostFrom / specs/HostCaret.tla.
    private func moveToParagraphOffset(_ offset: Int) {
        let text = transcribedText
        var unitAnchor: Int? = nil
        if let idx = paragraphNavIndex {
            let ranges = TranscriptSelection.paragraphRanges(text)
            if ranges.indices.contains(idx) {
                if paragraphSelectionActive {
                    textInserter.clearSelection()
                    unitAnchor = ranges[idx].end
                    paragraphSelectionActive = false
                    lineNavIndex = nil
                    lineSelectionActive = false
                } else {
                    unitAnchor = ranges[idx].start
                }
            }
        }
        let from = SessionCaretDecision.hostFrom(
            bufferCount: text.count,
            sessionCaret: sessionCaret,
            unitAnchor: unitAnchor
        )
        let delta = SessionCaretDecision.moveDelta(from: from, to: offset)
        if delta > 0 { textInserter.moveForward(count: delta) }
        if delta < 0 { textInserter.moveBackward(count: -delta) }
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

        // Void already-typed session text (Dragon-style). Dual: CancelVoid.tla /
        // CancelDecision — batch mode deletes nothing (nothing typed mid-session).
        let n = CancelDecision.appCharsToDelete(
            typedLength: transcribedText.count,
            typesIncrementally: pipelineTypesIncrementally
        )
        if n > 0 {
            textInserter.deleteBackward(count: n)
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
        editStack.clear()
        capsMode = .normal
        capitalizeNextWord = false
        spellMode = .off
        noSpaceMode = .off
        awaitingReplace = false
        sessionSelection = nil
        sessionCaret = nil
        lastCommittedNormalized = ""
        sentenceNavIndex = nil
        sentenceSelectionActive = false
        paragraphNavIndex = nil
        paragraphSelectionActive = false
        lineNavIndex = nil
        lineSelectionActive = false
        wordNavIndex = nil
        wordSelectionActive = false
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
