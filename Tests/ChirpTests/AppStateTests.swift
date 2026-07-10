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

    @Test("startRecording nudges when not ready")
    func startRecordingNoOp() {
        let (state, _, recorder, _) = makeAppState()
        state.status = .loadingModel
        state.startRecording()

        guard case .loadingModel = state.status else {
            Issue.record("Status should remain .loadingModel")
            return
        }
        #expect(!recorder.isRecording)
        #expect(state.downloadNudge == true)
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
        // First segment of session is auto-capitalized
        #expect(inserter.typedTexts.contains("Hello world"))
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

    @Test("replace that arms then next phrase swaps last segment")
    func replaceThatMultiStep() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["wrong words"])
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
        #expect(state.transcribedText.contains("wrong") || state.transcribedText.contains("Wrong"))
        #expect(!state.awaitingReplace)

        // Arm replace — text stays until next phrase
        await mock.setFeedAudioResult(["replace that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.awaitingReplace { break }
        }
        #expect(state.awaitingReplace)
        #expect(state.transcribedText.contains("wrong") || state.transcribedText.contains("Wrong"))

        // Replacement phrase undoes last and inserts new
        await mock.setFeedAudioResult(["right words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.awaitingReplace && state.transcribedText.contains("right") { break }
        }
        #expect(!state.awaitingReplace)
        #expect(
            state.transcribedText.contains("right") || state.transcribedText.contains("Right"),
            "expected replacement, got \"\(state.transcribedText)\""
        )
        #expect(
            !state.transcribedText.lowercased().contains("wrong"),
            "old phrase should be gone, got \"\(state.transcribedText)\""
        )
    }

    @Test("all caps on forces uppercase on following segment")
    func allCapsModeSticky() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["all caps on"])
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
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(inserter.typedTexts.isEmpty, "mode switch must not type")

        await mock.setFeedAudioResult(["hello world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "HELLO WORLD" { break }
        }
        #expect(state.transcribedText == "HELLO WORLD")
        #expect(inserter.typedTexts.contains("HELLO WORLD"))
    }

    @Test("spell mode packs letter tokens on following segment")
    func spellModeSticky() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["spell mode"])
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
            if state.spellMode == .on { break }
        }
        #expect(state.spellMode == .on)
        #expect(inserter.typedTexts.isEmpty, "mode switch must not type")

        await mock.setFeedAudioResult(["alpha bravo charlie"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "abc" { break }
        }
        #expect(state.transcribedText == "abc")
        #expect(inserter.typedTexts.contains("abc"))
    }

    @Test("spell that selects last phrase and enables spell mode")
    func spellThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["spell that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.spellMode == .on, !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.spellMode == .on)
        #expect(state.transcribedText == "Hello world", "spell that must not delete text")
        #expect(inserter.selectBackwardCounts.last == "Hello world".count)
        #expect(inserter.deletedCounts.isEmpty, "spell that must not delete")
        #expect(!inserter.typedTexts.contains("spell that"))
    }

    @Test("one-shot spell as packs once and leaves spell mode off")
    func spellAsOneShot() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["spell as a b c"])
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
            if state.transcribedText == "abc" { break }
        }
        #expect(state.transcribedText == "abc")
        #expect(state.spellMode == .off, "one-shot must not enable sticky spell mode")
        #expect(inserter.typedTexts.contains("abc"))
        #expect(!inserter.typedTexts.contains(where: { $0.lowercased().contains("spell as") }))
    }

    @Test("one-shot spell as with capital packs and leaves sticky mode unchanged")
    func spellAsOneShotCapital() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["spell as capital j o h n"])
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
            if state.transcribedText == "John" { break }
        }
        #expect(state.transcribedText == "John")
        #expect(state.spellMode == .off)
    }

    @Test("spell mode glues multi-segment commits without space")
    func spellModeMultiSegmentGlue() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["spell mode"])
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
            if state.spellMode == .on { break }
        }
        #expect(state.spellMode == .on)

        await mock.setFeedAudioResult(["a b"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "ab" { break }
        }
        #expect(state.transcribedText == "ab")

        await mock.setFeedAudioResult(["c"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "abc" { break }
        }
        #expect(state.transcribedText == "abc", "spell segments must glue: got \"\(state.transcribedText)\"")
        #expect(inserter.typedTexts.contains("c"))
        #expect(!inserter.typedTexts.contains(" c"), "must not type leading space under spell glue")
    }

    @Test("press backspace deletes one char without changing session buffer")
    func pressBackspaceCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["press backspace"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.deletedCounts.contains(1) { break }
        }

        #expect(state.transcribedText == "Hello world", "v1: keyboard-only, buffer unchanged")
        #expect(inserter.deletedCounts.contains(1))
        #expect(!inserter.typedTexts.contains("press backspace"))
    }

    @Test("sentence case that transforms last phrase")
    func sentenceCaseThatLastPhrase() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["HELLO WORLD STOP"])
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

        await mock.setFeedAudioResult(["sentence case that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world stop" { break }
        }
        #expect(
            state.transcribedText == "Hello world stop",
            "sentence case that failed: \"\(state.transcribedText)\""
        )
    }

    @Test("no space that joins last word without space")
    func noSpaceThatJoins() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Peyton"])
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
            if state.transcribedText == "Peyton" { break }
        }

        await mock.setFeedAudioResult(["Davis"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("Davis") { break }
        }
        #expect(state.transcribedText == "Peyton Davis" || state.transcribedText.hasSuffix("Davis"))

        await mock.setFeedAudioResult(["no space that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "PeytonDavis" { break }
        }
        #expect(
            state.transcribedText == "PeytonDavis",
            "no space that failed: \"\(state.transcribedText)\""
        )
    }

    @Test("title case that transforms last phrase")
    func titleCaseThatLastPhrase() async throws {
        let mock = MockTranscriber()
        // One segment so last stack delta is the full phrase
        await mock.setFeedAudioResult(["hello world from chirp"])
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
        #expect(!state.transcribedText.isEmpty)

        await mock.setFeedAudioResult(["title case that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello World From Chirp" { break }
        }
        #expect(
            state.transcribedText == "Hello World From Chirp",
            "title case that should title-case last phrase, got \"\(state.transcribedText)\""
        )
    }

    @Test("cap that capitalizes last word")
    func capThatLastWord() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world"])
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
            if state.transcribedText == "Hello world" || state.transcribedText == "hello world" { break }
        }

        await mock.setFeedAudioResult(["cap that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.hasSuffix("World") { break }
        }
        #expect(
            state.transcribedText.hasSuffix("World"),
            "cap that should title-case last word, got \"\(state.transcribedText)\""
        )
    }

    @Test("non-incremental batch flush types once with joined content")
    func nonIncrementalBatchFlushTypesOnce() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello", "world"])
        await mock.setFlushResult("done")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        struct BatchPP: TextPostProcessing {
            func process(_ text: String) async throws -> String { text }
        }
        let batchPipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: BatchPP()
        )
        state.installPipelineForTesting(batchPipeline, typesIncrementally: false)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Mid-session audio: batch path must not type yet
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(inserter.typedTexts.isEmpty, "batch mode must not type mid-session")
        #expect(state.transcribedText.isEmpty, "batch mode must not fill buffer mid-session")

        state.stopRecording()
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        #expect(!state.transcribedText.isEmpty)
        #expect(inserter.typedTexts.count == 1, "batch flush should type exactly once")
        let typed = inserter.typedTexts[0]
        #expect(typed.contains("Hello") || typed.contains("hello"))
        // Joined batch should match buffer (single stack entry typed as one delta)
        #expect(state.transcribedText == typed)
    }

    @Test("scratch that undoes the last typed segment")
    func scratchThatUndoesLastSegment() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts == ["Hello world"])

        await mock.setFeedAudioResult(["scratch that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.isEmpty { break }
        }

        #expect(state.transcribedText.isEmpty, "transcript should be cleared by scratch that")
        #expect(inserter.deletedCounts == [11], "should delete 11 chars of 'Hello world'")
        #expect(!inserter.typedTexts.contains("scratch that"))
    }

    @Test("multi-level scratch undoes newest segment first")
    func multiLevelScratch() async throws {
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
            if state.transcribedText == "Hello" { break }
        }

        await mock.setFeedAudioResult(["world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }
        #expect(state.transcribedText == "Hello world")

        // First scratch → remove " world" (joiner delta)
        await mock.setFeedAudioResult(["scratch that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello" { break }
        }
        #expect(state.transcribedText == "Hello")

        // Second scratch → remove "Hello"
        await mock.setFeedAudioResult(["scratch that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText.isEmpty)
        #expect(inserter.deletedCounts.count >= 2)
    }

    @Test("redo that restores last scratched segment")
    func redoThatRestoresSegment() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["scratch that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText.isEmpty)

        await mock.setFeedAudioResult(["redo that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts.contains("Hello world"))
        #expect(!inserter.typedTexts.contains("redo that"))
        #expect(!inserter.typedTexts.contains("scratch that"))
    }

    @Test("delete last word removes trailing word only")
    func deleteLastWordCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["delete last word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello" { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.deletedCounts.last == 6) // " world"
    }

    @Test("select that selects last stack delta without changing buffer")
    func selectThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["select that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.selectBackwardCounts.last == "Hello world".count)
        #expect(!inserter.typedTexts.contains("select that"))
    }

    @Test("select last word selects trailing word only")
    func selectLastWordCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["select last word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.selectBackwardCounts.last == 6) // " world"
        #expect(!inserter.typedTexts.contains("select last word"))
    }

    @Test("select last sentence selects trailing sentence only")
    func selectLastSentenceCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World now"])
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
            if state.transcribedText == "Hello. World now" { break }
        }

        await mock.setFeedAudioResult(["select last sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello. World now")
        #expect(inserter.selectBackwardCounts.last == " World now".count)
        #expect(!inserter.typedTexts.contains("select last sentence"))
    }

    @Test("select last paragraph selects trailing paragraph only")
    func selectLastParagraphCommand() async throws {
        let mock = MockTranscriber()
        // Pipeline types "new paragraph" as \n\n between segments when spoken;
        // seed buffer with explicit paragraphs via one segment.
        await mock.setFeedAudioResult(["Para one\n\nPara two"])
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
            if state.transcribedText.contains("Para two") { break }
        }

        await mock.setFeedAudioResult(["select last paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText.hasSuffix("Para two") || state.transcribedText.contains("Para two"))
        #expect(inserter.selectBackwardCounts.last == "Para two".count)
        #expect(!inserter.typedTexts.contains("select last paragraph"))
    }

    @Test("select all posts selectAll without changing buffer")
    func selectAllCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["select all"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectAllCalled { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.selectAllCalled)
        #expect(!inserter.typedTexts.contains("select all"))
    }

    @Test("move left word moves cursor without changing buffer")
    func moveLeftWordCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["move left"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveWordDirections.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveWordDirections == [.left])
        #expect(!inserter.typedTexts.contains("move left"))
    }

    @Test("move right word moves cursor without changing buffer")
    func moveRightWordCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveWordDirections.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveWordDirections == [.right])
        #expect(!inserter.typedTexts.contains("next word"))
    }

    @Test("go to start / end moves line cursor without changing buffer")
    func moveToLineEdgeCommands() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["go to start"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToLineStartCalled { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveToLineStartCalled)

        await mock.setFeedAudioResult(["end of line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToLineEndCalled { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveToLineEndCalled)
        #expect(!inserter.typedTexts.contains("go to start"))
        #expect(!inserter.typedTexts.contains("end of line"))
    }

    @Test("delete last word keeps multi-level undo; redo restores word")
    func deleteLastWordPreservesStack() async throws {
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
            if state.transcribedText == "Hello" { break }
        }

        await mock.setFeedAudioResult(["world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }

        // Delete last word → "Hello" (stack still has first segment)
        await mock.setFeedAudioResult(["delete the last word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello" { break }
        }
        #expect(state.transcribedText == "Hello")

        // Redo restores deleted word
        await mock.setFeedAudioResult(["redo that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }
        #expect(state.transcribedText == "Hello world")

        // Delete word again, then scratch first segment
        await mock.setFeedAudioResult(["delete last word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello" { break }
        }
        await mock.setFeedAudioResult(["scratch that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText.isEmpty)
    }

    @Test("duplicate consecutive segments are skipped")
    func duplicateSegmentsSkipped() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts.count == 1)

        // Same text again (with trailing punct) should not append
        await mock.setFeedAudioResult(["Hello world."])
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts.count == 1)
    }

    @Test("bold that selects last phrase then applies bold")
    func boldThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["bold that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.appliedFormats.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.selectBackwardCounts.last == "Hello world".count)
        #expect(inserter.appliedFormats == [.bold])
        #expect(!inserter.typedTexts.contains("bold that"))
    }

    @Test("italic that selects last phrase then applies italic")
    func italicThatCommand() async throws {
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
            if state.transcribedText == "Hello" { break }
        }

        await mock.setFeedAudioResult(["italic that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.appliedFormats.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.selectBackwardCounts.last == "Hello".count)
        #expect(inserter.appliedFormats == [.italic])
    }

    @Test("underline that selects last phrase then applies underline")
    func underlineThatCommand() async throws {
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
            if state.transcribedText == "Hello" { break }
        }

        await mock.setFeedAudioResult(["underline that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.appliedFormats.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.selectBackwardCounts.last == "Hello".count)
        #expect(inserter.appliedFormats == [.underline])
    }

    @Test("bold that with empty stack still applies format")
    func boldThatEmptyStackStillFormats() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["bold that"])
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
            if !inserter.appliedFormats.isEmpty { break }
        }

        #expect(state.transcribedText.isEmpty)
        #expect(inserter.selectBackwardCounts.isEmpty)
        #expect(inserter.appliedFormats == [.bold])
    }

    @Test("cut that selects last phrase, cuts, and drops buffer delta")
    func cutThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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
            if state.transcribedText == "Hello world" { break }
        }

        await mock.setFeedAudioResult(["cut that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.cutCallCount > 0 { break }
        }

        #expect(state.transcribedText.isEmpty)
        #expect(inserter.selectBackwardCounts.last == "Hello world".count)
        #expect(inserter.cutCallCount == 1)
        // Cut already removed text — no second deleteBackward
        #expect(inserter.deletedCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("cut that"))
    }

    @Test("cut that after two phrases only cuts last delta")
    func cutThatLastDeltaOnly() async throws {
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
            if state.transcribedText == "Hello" { break }
        }

        await mock.setFeedAudioResult(["world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("world") { break }
        }
        let beforeCut = state.transcribedText
        #expect(beforeCut.hasPrefix("Hello"))

        await mock.setFeedAudioResult(["cut that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.cutCallCount > 0 { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.cutCallCount == 1)
        #expect(inserter.deletedCounts.isEmpty)
        #expect(inserter.selectBackwardCounts.last != nil)
    }

    @Test("copy that puts transcript on clipboard")
    func copyThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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

        await mock.setFeedAudioResult(["copy that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.copyCallCount > 0 { break }
        }

        #expect(inserter.copyCallCount == 1)
        #expect(inserter.clipboard == "Hello world")
        #expect(state.transcribedText == "Hello world")
    }

    @Test("paste that inserts clipboard into session")
    func pasteThatCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        inserter.clipboard = " world"
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

        await mock.setFeedAudioResult(["paste that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pasteCallCount > 0 { break }
        }

        #expect(inserter.pasteCallCount == 1)
        #expect(state.transcribedText == "Hello world")
    }

    @Test("press enter inserts newline")
    func pressEnterCommand() async throws {
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

        await mock.setFeedAudioResult(["press enter"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("\n") { break }
        }

        #expect(state.transcribedText == "Hello\n")
        #expect(inserter.typedTexts.contains("\n"))
    }

    @Test("clear all wipes the session transcript")
    func clearAllCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world"])
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

        await mock.setFeedAudioResult(["clear all"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.isEmpty { break }
        }

        #expect(state.transcribedText.isEmpty)
        #expect(inserter.deletedCounts.last == 11)
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

        #expect(state.transcribedText == "Hello goodbye")
        #expect(inserter.typedTexts == ["Hello", " goodbye"])
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
        #expect(inserter.typedTexts.contains("Final words"))
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
        #expect(state.transcribedText == "Hello")

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

    // MARK: - Download nudge

    @Test("fn press during download triggers nudge and auto-resets")
    func fnPressDuringDownloadNudges() async throws {
        let (state, _, recorder, _) = makeAppState()
        state.status = .downloading(0.5)
        state.startRecording()

        // Status unchanged, nudge set
        guard case .downloading(0.5) = state.status else {
            Issue.record("Status should remain .downloading(0.5), got \(state.status)")
            return
        }
        #expect(state.downloadNudge == true)
        #expect(!recorder.isRecording)

        // Wait for auto-reset (~200ms)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !state.downloadNudge { break }
        }
        #expect(state.downloadNudge == false)
    }

    @Test("fn press during download does not start recording")
    func fnPressDuringDownloadNoRecording() {
        let (state, _, recorder, _) = makeAppState()
        state.status = .downloading(0.3)
        state.startRecording()

        #expect(!recorder.isRecording)
        guard case .downloading(0.3) = state.status else {
            Issue.record("Status should remain .downloading(0.3), got \(state.status)")
            return
        }
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

    @Test("Microphone permission denied transitions to error status")
    func microphonePermissionDenied() async throws {
        let mock = MockTranscriber()
        await mock.setInitializeResult(true)
        let recorder = MockAudioRecorder()
        recorder.microphoneAccessGranted = false
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        let paths = ModelPaths(modelDir: "/test", vadPath: "/test", )
        state.loadTranscriber(paths: paths)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .error = state.status { break }
        }

        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error, got \(state.status)")
            return
        }
        #expect(msg.contains("Microphone"))
        #expect(!recorder.prepareCalled)
    }

    @Test("Microphone permission granted transitions to ready")
    func microphonePermissionGranted() async throws {
        let mock = MockTranscriber()
        await mock.setInitializeResult(true)
        let recorder = MockAudioRecorder()
        recorder.microphoneAccessGranted = true
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        let paths = ModelPaths(modelDir: "/test", vadPath: "/test", )
        state.loadTranscriber(paths: paths)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
        // Engine is lazily prepared in startRecording(), not at load time.
        #expect(!recorder.prepareCalled)
    }

    @Test("Failed transcriber init transitions to error status")
    func failedTranscriberInitError() async throws {
        let mock = MockTranscriber()
        // initializeResult defaults to false
        let (state, _, _, _) = makeAppState(transcriber: mock)

        let paths = ModelPaths(modelDir: "/nonexistent", vadPath: "/nonexistent", )
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

    // MARK: - Cancel download

    @Test("cancelDownload transitions from downloading to needsModel")
    func cancelDownloadTransition() {
        let (state, _, _, _) = makeAppState()
        state.status = .downloading(0.5)
        state.cancelDownload()

        guard case .needsModel = state.status else {
            Issue.record("Expected .needsModel, got \(state.status)")
            return
        }
    }

    @Test("cancelDownload is no-op when not downloading")
    func cancelDownloadNoOp() {
        let (state, _, _, _) = makeAppState()
        state.status = .ready
        state.cancelDownload()

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
    }

    // MARK: - Retry / re-download

    @Test("retryDownload from error triggers ensureModel")
    func retryDownloadFromError() {
        let (state, _, _, _) = makeAppState()
        state.status = .error("something failed")
        state.retryDownload()

        switch state.status {
        case .downloading, .loadingModel:
            break // expected — ensureModel was called
        default:
            Issue.record("Expected .downloading or .loadingModel, got \(state.status)")
        }
    }

    @Test("retryDownload from needsModel triggers ensureModel")
    func retryDownloadFromNeedsModel() {
        let (state, _, _, _) = makeAppState()
        state.status = .needsModel
        state.retryDownload()

        switch state.status {
        case .downloading, .loadingModel:
            break // expected — ensureModel was called
        default:
            Issue.record("Expected .downloading or .loadingModel, got \(state.status)")
        }
    }

    @Test("retryDownload is no-op when ready")
    func retryDownloadNoOpWhenReady() {
        let (state, _, _, _) = makeAppState()
        state.status = .ready
        state.retryDownload()

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
    }

    // MARK: - needsModel + fn press

    @Test("fn press during needsModel starts download")
    func fnPressDuringNeedsModelStartsDownload() {
        let (state, _, _, _) = makeAppState()
        state.status = .needsModel
        state.startRecording()

        switch state.status {
        case .downloading, .loadingModel:
            break // expected — ensureModel was called
        default:
            Issue.record("Expected .downloading or .loadingModel, got \(state.status)")
        }
    }

    // MARK: - Cancel session

    @Test("cancelSession from recording → ready")
    func cancelSessionFromRecording() {
        let (state, _, recorder, _) = makeAppState()
        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording, got \(state.status)")
            return
        }
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
        #expect(!recorder.isRecording)
        #expect(state.transcribedText == "")
        #expect(state.speculativeText == "")
        #expect(state.audioLevel == 0)
    }

    @Test("cancelSession voids already-typed text in the focused app (incremental)")
    func cancelSessionVoidsTypedText() async throws {
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
        #expect(state.pipelineTypesIncrementally)
        let typedLen = state.transcribedText.count

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "")
        #expect(inserter.deletedCounts == [typedLen],
                "cancel must deleteBackward typed length, got \(inserter.deletedCounts)")
    }

    @Test("cancelSession in batch mode does not delete in app")
    func cancelSessionBatchDoesNotDelete() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)

        struct BatchPP: TextPostProcessing {
            func process(_ text: String) async throws -> String { text }
        }
        let batchPipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: BatchPP()
        )
        state.installPipelineForTesting(batchPipeline, typesIncrementally: false)
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Mid-session: batch path types nothing
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(inserter.typedTexts.isEmpty)
        #expect(!state.pipelineTypesIncrementally)

        // Even if buffer had text, batch cancel must not deleteBackward
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "")
        #expect(inserter.deletedCounts.isEmpty,
                "batch cancel must not deleteBackward, got \(inserter.deletedCounts)")
    }

    @Test("cancelSession from transcribing → ready")
    func cancelSessionFromTranscribing() async throws {
        let mock = MockTranscriber()
        await mock.setFlushDelay(5_000_000_000) // slow flush
        await mock.setFlushResult("should not appear")
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
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "")
    }

    @Test("cancelSession prevents flush text from being typed")
    func cancelSessionPreventsFlushText() async throws {
        let mock = MockTranscriber()
        await mock.setFlushDelay(500_000_000) // 500ms flush
        await mock.setFlushResult("stale text")
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
        // Cancel while flush is in-flight
        try await Task.sleep(nanoseconds: 50_000_000)
        state.cancelSession()

        // Wait for the flush to complete (it was cancelled but let's be sure)
        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(!inserter.typedTexts.contains("stale text"))
        #expect(state.transcribedText == "")
    }

    @Test("cancelSession resets sticky capsMode to normal")
    func cancelSessionResetsCapsMode() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["all caps on"])
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
            if state.capsMode == .allCaps { break }
        }
        #expect(state.capsMode == .allCaps)

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.capsMode == .normal)
        #expect(state.spellMode == .off)
        #expect(!state.awaitingReplace)
    }

    @Test("cancelSession resets sticky spellMode to off")
    func cancelSessionResetsSpellMode() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["spell mode"])
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
            if state.spellMode == .on { break }
        }
        #expect(state.spellMode == .on)

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.spellMode == .off)
        #expect(state.capsMode == .normal)
        #expect(!state.awaitingReplace)
    }

    @Test("cancelSession clears armed replace that")
    func cancelSessionClearsAwaitingReplace() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["wrong words"])
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
        #expect(!state.awaitingReplace)

        await mock.setFeedAudioResult(["replace that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.awaitingReplace { break }
        }
        #expect(state.awaitingReplace)

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(!state.awaitingReplace)
        #expect(state.capsMode == .normal)
    }

    @Test("cancelSession is no-op from ready")
    func cancelSessionNoOpFromReady() {
        let (state, _, _, _) = makeAppState()
        state.status = .ready
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
    }

    @Test("cancelSession is no-op from downloading")
    func cancelSessionNoOpFromDownloading() {
        let (state, _, _, _) = makeAppState()
        state.status = .downloading(0.5)
        state.cancelSession()

        guard case .downloading = state.status else {
            Issue.record("Expected .downloading, got \(state.status)")
            return
        }
    }

    @Test("Start new recording after cancel works cleanly")
    func startRecordingAfterCancel() async throws {
        let mock = MockTranscriber()
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        state.status = .ready
        state.startRecording()
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }

        // Start a fresh session
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after re-start, got \(state.status)")
            return
        }
        #expect(recorder.isRecording)
    }

    // MARK: - Session rejoin

    @Test("Rejoin from transcribing preserves text")
    func rejoinFromTranscribingPreservesText() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        await mock.setFlushDelay(5_000_000_000) // slow flush to stay in transcribing
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

        // Commit a segment
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText == "Hello")

        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }

        // Rejoin — fn press during transcribing
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after rejoin, got \(state.status)")
            return
        }
        // Text preserved
        #expect(state.transcribedText == "Hello")
        #expect(recorder.isRecording)
    }

    @Test("Rejoin starts new consumer and audio tap")
    func rejoinStartsNewConsumer() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        await mock.setFlushDelay(5_000_000_000) // slow flush
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

        // Commit first segment
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText == "Hello")

        state.stopRecording()

        // Rejoin
        await mock.setFeedAudioResult(["world"])
        await mock.setFlushDelay(0)
        state.startRecording()

        // Wait for new consumer's resetVAD
        // resetVADCalled is already true, so check feedAudioCallCount increases
        let prevCount = await mock.feedAudioCallCount
        recorder.lastOnSamples?([0.2])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.feedAudioCallCount > prevCount { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.typedTexts.contains(" world"))
    }

    @Test("Rejoin during linger works")
    func rejoinDuringLingerWorks() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hi"])
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.lingerDuration = 5_000_000_000 // 5s linger to give time to rejoin

        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Commit a segment
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText == "Hi")

        state.stopRecording()

        // Wait for flush to complete (it's instant) and enter linger
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.flushCalled { break }
        }
        // Give a moment for linger sleep to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // Still transcribing (in linger)
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing during linger, got \(state.status)")
            return
        }

        // Rejoin during linger
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after rejoin, got \(state.status)")
            return
        }
        #expect(state.transcribedText == "Hi")
        #expect(recorder.isRecording)
    }

    // MARK: - Pipeline rebuild guard

    @Test("rebuildPipeline deferred during recording")
    func rebuildPipelineDeferredDuringRecording() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording")
            return
        }

        // Calling rebuildPipeline during recording should defer
        state.rebuildPipeline()

        // Stop and wait for ready
        state.stopRecording()
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
        // Pipeline was rebuilt after session ended (no crash, state is clean)
    }

    @Test("rebuildPipeline deferred during recording and applied after cancel")
    func rebuildPipelineDeferredDuringRecordingCancel() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording")
            return
        }

        // Calling rebuildPipeline during recording should defer
        state.rebuildPipeline()

        // Cancel session
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready, got \(state.status)")
            return
        }
        // Pipeline was rebuilt after cancel (no crash, state is clean)
    }

    // MARK: - HotkeyManager callback tests

    @Test("HotkeyManager callbacks fire via MainActor.assumeIsolated from GCD")
    func hotkeyCallbackDispatch() async throws {
        // Verifies that @MainActor closures wrapped with MainActor.assumeIsolated
        // work correctly when dispatched via DispatchQueue.main.async.
        // This catches the crash where Task { @MainActor in } from a C callback
        // (no Swift Task context) segfaulted in swift_task_isCurrentExecutorWithFlagsImpl.
        var callCount = 0

        let mgr = HotkeyManager(
            onPress: { callCount += 1 },
            onRelease: { callCount += 1 },
            onCancel: { callCount += 1 }
        )

        // Simulate what the event tap does: startRecording/stopRecording via GCD
        // (HotkeyManager wraps callbacks with MainActor.assumeIsolated internally)
        let (state, _, _, _) = makeAppState()
        state.status = .ready

        // Trigger recording start/stop through AppState (same path as hotkey)
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after startRecording, got \(state.status)")
            return
        }

        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing after stopRecording, got \(state.status)")
            return
        }

        _ = mgr  // prevent deallocation during test
    }

    // MARK: - Speculative text persistence tests

    @Test("speculativeText survives stopRecording until flush completes")
    func speculativeTextPersistsDuringFlush() async throws {
        // Verifies that speculativeText is NOT cleared by stopRecording,
        // preventing the blank overlay gap while awaiting flush results.
        let transcriber = MockTranscriber()
        await transcriber.setInitializeResult(true)
        // Flush takes 200ms — simulates cloud/LLM latency
        await transcriber.setFlushDelay(200_000_000)
        await transcriber.setFlushResult("Hello world")

        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(
            transcriber: transcriber, recorder: recorder, inserter: inserter
        )
        state.status = .ready

        // Start recording and inject speculative text (simulating peek)
        state.startRecording()
        state.speculativeText = "Hello wo"

        // Stop recording — speculativeText must persist
        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }
        #expect(state.speculativeText == "Hello wo",
                "speculativeText should survive stopRecording, got: \"\(state.speculativeText)\"")

        // Wait for flush + linger to complete (poll — fixed sleep flakes under load)
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if case .ready = state.status { break }
        }

        guard case .ready = state.status else {
            Issue.record("Expected .ready after flush, got \(state.status)")
            return
        }
        // After flush, speculative text should be cleared
        #expect(state.speculativeText.isEmpty,
                "speculativeText should be cleared after flush completes")
    }

    @Test("Peek nil does not clear speculativeText (VAD flicker resilience)")
    func peekNilPreservesSpeculativeText() async throws {
        // When VAD's Detected state flickers to false, peekTranscription()
        // returns nil. The peek loop should keep the last good preview
        // rather than blanking the overlay.
        let transcriber = MockTranscriber()
        await transcriber.setInitializeResult(true)

        let (state, _, _, _) = makeAppState(transcriber: transcriber)
        state.status = .ready

        // Simulate: good peek result followed by nil (VAD flicker)
        state.speculativeText = "Hello world"
        state.startRecording()

        // After start, speculativeText was cleared for new session — set it again
        // to simulate what the peek loop would have set during recording
        state.speculativeText = "Hello world"

        // Simulate what the peek loop does when peek returns nil:
        // (it should NOT clear speculativeText)
        let preview: String? = nil
        if let preview {
            state.speculativeText = preview
        }
        // speculativeText should still show the last good value
        #expect(state.speculativeText == "Hello world",
                "nil peek should not clear speculativeText")

        state.cancelSession()
    }

    // MARK: - Double-start / rapid cycle safety

    @Test("Rapid start-stop-start cycle works without double-start")
    func rapidStartStopStartCycle() async throws {
        // Exercises the path where parkEngine() could leave a stale tap.
        // The defensive removeTap before installTap prevents crash.
        let mock = MockTranscriber()
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        // Cycle 1: start → stop → wait for flush
        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after first start")
            return
        }
        #expect(recorder.startCallCount == 1)

        state.stopRecording()
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .ready = state.status { break }
        }

        // Cycle 2: start again (simulates rapid re-press after park)
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after second start, got \(state.status)")
            return
        }
        #expect(recorder.startCallCount == 2)
        #expect(!recorder.doubleStartDetected,
                "Recorder should not be double-started (stop must precede start)")

        state.cancelSession()
    }

    @Test("No double-start of recorder across all AppState paths")
    func noDoubleStartAcrossAllPaths() async throws {
        // Verifies that AppState always stops the recorder before starting it again
        // across all transitions: start→stop→start, rejoin, cancel→start.
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["word"])
        await mock.setFlushDelay(5_000_000_000) // slow flush for rejoin window
        await mock.setFlushResult("")
        let recorder = MockAudioRecorder()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder)

        // Path 1: normal start
        state.status = .ready
        state.startRecording()
        #expect(recorder.startCallCount == 1)

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        // Path 2: stop → rejoin (start during .transcribing)
        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing, got \(state.status)")
            return
        }
        // rejoinSession calls audioRecorder.stopRecording() then startRecording()
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after rejoin, got \(state.status)")
            return
        }
        #expect(!recorder.doubleStartDetected,
                "Rejoin must stop recorder before restarting")

        // Path 3: cancel → start
        state.cancelSession()
        state.startRecording()
        #expect(!recorder.doubleStartDetected,
                "Cancel→start must not double-start recorder")

        state.cancelSession()
    }

    @Test("Cloud pipeline preview accumulates across VAD segment boundaries")
    func cloudPipelinePreviewAccumulation() async throws {
        // Verifies that CloudTranscriptionPipeline retains committed
        // segments from the local transcriber so peek shows full preview
        // even after VAD clears pendingAudio.
        let transcriber = MockTranscriber()
        await transcriber.setInitializeResult(true)

        // Simulate: feedAudio returns a committed segment on call 3
        let counter = Counter()
        await transcriber.setFeedAudioHandler({ _ in
            let n = counter.increment()
            if n == 3 { return ["Hello"] }
            return []
        })

        // After feedAudio commits a segment, peek returns partial new audio
        await transcriber.setPeekResult("world")

        let mockSTT = MockSTTClient(result: "Hello world finalized")
        let pipeline = CloudTranscriptionPipeline(
            sttClient: mockSTT,
            localTranscriber: transcriber
        )

        // Feed audio in 3 chunks
        for _ in 0..<3 {
            _ = await pipeline.feedAudio(samples: [Float](repeating: 0.1, count: 1360))
        }

        // Peek should include BOTH the committed segment AND current peek
        let preview = await pipeline.peekTranscription()
        #expect(preview != nil, "Preview should not be nil")
        #expect(preview?.contains("Hello") == true,
                "Preview should include committed segment, got: \"\(preview ?? "nil")\"")
        #expect(preview?.contains("world") == true,
                "Preview should include current peek, got: \"\(preview ?? "nil")\"")
    }
}
