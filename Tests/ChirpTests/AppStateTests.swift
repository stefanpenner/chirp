import Testing
import Foundation
@testable import Chirp

@Suite("AppState")
@MainActor
struct AppStateTests {

    private func makeAppState(
        transcriber: MockTranscriber = MockTranscriber(),
        recorder: MockAudioRecorder = MockAudioRecorder(),
        inserter: MockTextInserter = MockTextInserter(),
        modelFileCheck: @escaping () -> Bool = { true }
    ) -> (AppState, MockTranscriber, MockAudioRecorder, MockTextInserter) {
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter,
            startListening: false
        )
        state.modelFileCheck = modelFileCheck
        state.lingerDuration = 1_000_000 // 1ms — don't slow down tests
        return (state, transcriber, recorder, inserter)
    }

    @Test("Initial status is loadingModel or downloading")
    func initialStatus() {
        let (state, _, _, _) = makeAppState()
        switch state.status {
        case .loadingModel, .downloading:
            break // valid initial states
        default:
            Issue.record("Expected .loadingModel or .downloading, got \(state.status)")
        }
    }

    @Test("startRecording transitions ready → recording")
    func startRecordingTransition() async {
        let (state, _, recorder, _) = makeAppState()
        state.status = .ready
        state.startRecording()

        guard case .recording = state.status else {
            Issue.record("Expected .recording, got \(state.status)")
            return
        }
        #expect(recorder.isRecording)
    }

    @Test("startRecording resets VAD")
    func startRecordingResetsVAD() async throws {
        let mock = MockTranscriber()
        let (state, _, _, _) = makeAppState(transcriber: mock)
        state.status = .ready
        state.startRecording()

        // Poll until the spawned Task calls resetVAD (up to 3s for slow CI)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }
        #expect(await mock.resetVADCalled)
    }

    @Test("startRecording no-ops when not ready")
    func startRecordingNoOp() {
        let (state, _, recorder, _) = makeAppState()
        state.status = .loadingModel
        state.startRecording()

        guard case .loadingModel = state.status else {
            Issue.record("Status should remain .loadingModel")
            return
        }
        #expect(!recorder.isRecording)
    }

    @Test("stopRecording transitions recording → transcribing")
    func stopRecordingTransition() {
        let (state, _, _, _) = makeAppState()
        state.status = .recording
        state.stopRecording()

        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }
    }

    @Test("stopRecording calls flush and types result")
    func stopRecordingFlushAndType() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("hello world")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        // Poll until the spawned Task calls flush (up to 3s for slow CI)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.flushCalled { break }
        }
        #expect(await mock.flushCalled)
        #expect(inserter.typedTexts.contains("hello world"))
    }

    // MARK: - Audio level

    @Test("Audio level computed from RMS formula")
    func audioLevelFromRMS() async throws {
        let mock = MockTranscriber()
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // RMS of [0.1, 0.1, 0.1, 0.1] = sqrt(0.04/4) = 0.1
        // level = min(0.1 * 6, 1) = 0.6
        recorder.lastOnSamples?([0.1, 0.1, 0.1, 0.1])

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.feedAudioCallCount > 0 { break }
        }

        #expect(abs(state.audioLevel - 0.6) < 0.01)
    }

    @Test("Audio level clamps to 1.0 for loud input")
    func audioLevelClampsToOne() async throws {
        let mock = MockTranscriber()
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // RMS of [1.0, 1.0] = 1.0, level = min(1.0 * 6, 1) = 1.0
        recorder.lastOnSamples?([1.0, 1.0])

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.feedAudioCallCount > 0 { break }
        }

        #expect(state.audioLevel == 1.0)
    }

    // MARK: - Text concatenation / spacing

    @Test("First segment has no leading space")
    func firstSegmentNoLeadingSpace() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        recorder.lastOnSamples?([0.1])

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.typedTexts == ["Hello"])
    }

    @Test("Subsequent segments get space separator")
    func subsequentSegmentsGetSpace() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // First segment
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText == "Hello")

        // Second segment
        await mock.setFeedAudioResult(["world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts == ["Hello", " world"])
    }

    @Test("Committed segment clears speculativeText")
    func committedSegmentClearsSpeculative() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.speculativeText = "partial preview"
        recorder.lastOnSamples?([0.1])

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }

        #expect(state.speculativeText == "")
        #expect(state.transcribedText == "Hello")
    }

    // MARK: - stopRecording edge cases

    @Test("stopRecording flush appends with space")
    func stopRecordingFlushAppendsWithSpace() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello"])
        await mock.setFlushResult("goodbye")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Inject samples so feedAudio returns "hello"
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }

        state.stopRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        #expect(state.transcribedText == "hello goodbye")
        #expect(inserter.typedTexts == ["hello", " goodbye"])
    }

    @Test("stopRecording empty flush is no-op")
    func stopRecordingEmptyFlushIsNoOp() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        #expect(inserter.typedTexts.isEmpty)
    }

    @Test("stopRecording when not recording is no-op")
    func stopRecordingWhenNotRecordingIsNoOp() {
        let (state, _, _, _) = makeAppState()
        state.status = .ready
        state.stopRecording()

        guard case .ready = state.status else {
            Issue.record("Status should remain .ready, got \(state.status)")
            return
        }
    }

    @Test("Multiple start/stop cycles reset cleanly")
    func multipleCyclesResetCleanly() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        // Cycle 1
        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after first start")
            return
        }
        state.stopRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        #expect(state.transcribedText == "")
        #expect(state.speculativeText == "")
        #expect(state.audioLevel == 0)

        // Cycle 2
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after second start")
            return
        }
        #expect(recorder.isRecording)
        state.stopRecording()
    }

    @Test("stopRecording resets audioLevel to 0")
    func stopRecordingResetsAudioLevel() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Inject samples to set audioLevel
        recorder.lastOnSamples?([0.5, 0.5])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.audioLevel > 0 { break }
        }

        state.stopRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        #expect(state.audioLevel == 0)
    }

    // MARK: - Consumer flush lifecycle

    @Test("Consumer task flushes after stream ends and transitions to ready")
    func consumerHandlesFlush() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("final words")
        let inserter = MockTextInserter()
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        // Wait for resetVAD so consumer is running
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        // Status should be .transcribing while flush is in flight
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing immediately after stop, got \(state.status)")
            return
        }

        // Wait for flush to complete
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready after flush, got \(state.status)")
            return
        }
        #expect(await mock.flushCalled)
        #expect(inserter.typedTexts.contains("final words"))
    }

    @Test("startRecording cancels pending consumer task")
    func startRecordingCancelsPendingConsumer() async throws {
        let mock = MockTranscriber()
        // Slow flush — gives us time to start a new recording
        await mock.setFlushDelay(5_000_000_000) // 5s
        await mock.setFlushResult("stale")
        let inserter = MockTextInserter()
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        // Wait for consumer to be running
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Stop recording → consumer will try to flush (takes 5s)
        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }

        // Force status to .ready so startRecording proceeds.
        // (In production this only happens after flush, but we're
        // testing the defensive cancel in startRecording.)
        state.status = .ready
        state.startRecording()

        // The slow flush was cancelled — "stale" should never be typed
        // Give a moment for any stale work to land
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!inserter.typedTexts.contains("stale"))
    }

    @Test("In-flight feedAudio results survive stopRecording")
    func inFlightFeedAudioSurvivesStop() async throws {
        let mock = MockTranscriber()
        // feedAudio takes 500ms to simulate being mid-call when stop happens
        await mock.setFeedAudioDelay(500_000_000)
        await mock.setFeedAudioResult(["The quick brown"])
        await mock.setFlushResult("fox")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        state.status = .ready
        state.startRecording()

        // Wait for resetVAD so consumer is running
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Inject samples — feedAudio will take 500ms
        recorder.lastOnSamples?([0.1, 0.1, 0.1])

        // Brief pause then stop while feedAudio is still in-flight
        try await Task.sleep(nanoseconds: 100_000_000)
        state.stopRecording()

        // Wait for everything to complete
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready after flush, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "The quick brown fox")
        #expect(inserter.typedTexts == ["The quick brown", " fox"])
    }

    // MARK: - Overlay linger

    @Test("Overlay lingers in transcribing state after flush")
    func overlayLingersAfterFlush() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("hello")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.lingerDuration = 500_000_000 // 500ms

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        // Wait for flush to complete but not the linger
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if await mock.flushCalled { break }
        }
        // Give a moment for flush result to be processed
        try await Task.sleep(nanoseconds: 50_000_000)

        // Status should still be .transcribing during linger
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing during linger, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "hello")

        // Wait for linger to expire
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready after linger, got \(state.status)")
            return
        }
    }

    @Test("No linger when transcription is empty")
    func noLingerWhenEmpty() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.lingerDuration = 2_000_000_000 // 2s — would be obvious if it waited

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        // Should transition to .ready quickly without lingering
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready quickly (no linger), got \(state.status)")
            return
        }
        #expect(inserter.typedTexts.isEmpty)
    }

    // MARK: - Model recovery

    @Test("startRecording re-triggers ensureModel when model files are missing")
    func startRecordingRecoversFromMissingModel() {
        let (state, _, recorder, _) = makeAppState(modelFileCheck: { false })
        state.status = .ready

        state.startRecording()

        switch state.status {
        case .downloading, .loadingModel:
            break // recovery kicked in
        default:
            Issue.record("Expected .downloading or .loadingModel, got \(state.status)")
        }
        #expect(!recorder.isRecording)
    }

    // MARK: - Model loading

    @Test("Failed transcriber init transitions to error status")
    func failedTranscriberInitError() async throws {
        let mock = MockTranscriber()
        // initializeResult defaults to false
        let (state, _, _, _) = makeAppState(transcriber: mock)

        let paths = ModelPaths(modelDir: "/nonexistent", vadPath: "/nonexistent", variant: .tdt)
        state.loadTranscriber(paths: paths)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .error = state.status { break }
        }

        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error, got \(state.status)")
            return
        }
        #expect(msg.contains("Failed to initialize"))
    }
}

// Helper extension for setting mock values
extension MockTranscriber {
    func setFlushResult(_ value: String) {
        flushResult = value
    }
}
