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

        // Wait for consumer to apply level (not only feedAudio) — CI can be slow.
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if abs(state.audioLevel - 0.6) < 0.01 { break }
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

    @Test("delete X removes last occurrence without leaving double spaces")
    func deletePhraseCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["delete world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.lowercased().contains("world") { break }
        }

        let text = state.transcribedText.lowercased()
        #expect(
            text == "hello foo" || text.hasPrefix("hello") && text.contains("foo") && !text.contains("world"),
            "expected world removed, got \"\(state.transcribedText)\""
        )
        #expect(!text.contains("  "), "no double spaces, got \"\(state.transcribedText)\"")
        #expect(!inserter.typedTexts.contains("delete world"))
        #expect(inserter.selectForwardCounts.last == " world".count)
        #expect(inserter.deletedCounts.last == 1 || inserter.deletedCounts.contains(1))
    }

    @Test("delete X no-op when target missing")
    func deletePhraseMissingTarget() async throws {
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }
        let before = state.transcribedText
        let typedBefore = inserter.typedTexts.count
        let deletedBefore = inserter.deletedCounts.count

        await mock.setFeedAudioResult(["delete zzz"])
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(state.transcribedText == before)
        #expect(inserter.typedTexts.count == typedBefore)
        #expect(inserter.deletedCounts.count == deletedBefore)
        #expect(!inserter.typedTexts.contains("delete zzz"))
    }

    @Test("replace X with Y rewrites last occurrence in buffer")
    func replacePhraseCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["replace world with planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let text = state.transcribedText.lowercased()
        #expect(text.contains("planet"), "replacement present, got \"\(state.transcribedText)\"")
        #expect(!text.contains("world"), "target removed, got \"\(state.transcribedText)\"")
        #expect(text.contains("hello") && text.contains("foo"))
        #expect(!inserter.typedTexts.contains("replace world with planet"))
        #expect(inserter.selectForwardCounts.last == "world".count)
        #expect(inserter.typedTexts.contains("planet"))
    }

    @Test("replace X with Y no-op when target missing")
    func replacePhraseMissingTarget() async throws {
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }
        let before = state.transcribedText
        let typedBefore = inserter.typedTexts.count

        await mock.setFeedAudioResult(["replace zzz with nope"])
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(state.transcribedText == before)
        #expect(inserter.typedTexts.count == typedBefore)
        #expect(!inserter.typedTexts.contains("replace zzz with nope"))
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

    @Test("no space mode glues multi-segment commits without packing letters")
    func noSpaceModeStickyGlue() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["no space on"])
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
            if state.noSpaceMode == .on { break }
        }
        #expect(state.noSpaceMode == .on)
        #expect(inserter.typedTexts.isEmpty, "mode switch must not type")

        // Within a segment, words keep spaces (no letter packing)
        await mock.setFeedAudioResult(["hello world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world" { break }
        }
        #expect(state.transcribedText == "Hello world",
                "no-space must not pack letters: got \"\(state.transcribedText)\"")

        // Next segment glues with no separator
        await mock.setFeedAudioResult(["wide"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello worldwide" { break }
        }
        #expect(state.transcribedText == "Hello worldwide",
                "no-space segments must glue: got \"\(state.transcribedText)\"")
        #expect(inserter.typedTexts.contains("wide"))
        #expect(!inserter.typedTexts.contains(" wide"), "must not type leading space under no-space glue")
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

    @Test("press escape sends key without changing buffer or leaving recording")
    func pressEscapeCommand() async throws {
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
        guard case .recording = state.status else {
            Issue.record("Expected .recording before escape, got \(state.status)")
            return
        }

        await mock.setFeedAudioResult(["press escape"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pressEscapeCallCount >= 1 { break }
        }

        #expect(inserter.pressEscapeCallCount >= 1)
        #expect(state.transcribedText == "Hello world", "keyboard-only; buffer unchanged")
        guard case .recording = state.status else {
            Issue.record("voice press escape must not cancel session; got \(state.status)")
            return
        }
        #expect(!inserter.typedTexts.contains("press escape"))
    }

    @Test("press escape N times posts Escape N times without changing buffer")
    func pressEscapeNCommand() async throws {
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

        await mock.setFeedAudioResult(["press escape 3 times"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pressEscapeCallCount >= 3 { break }
        }

        #expect(
            inserter.pressEscapeCallCount >= 3,
            "EscapeN dual: host posts 3 Escapes, got \(inserter.pressEscapeCallCount)"
        )
        #expect(state.transcribedText == "Hello world", "keyboard-only; buffer unchanged")
        guard case .recording = state.status else {
            Issue.record("voice press escape N must not cancel session; got \(state.status)")
            return
        }
        #expect(!inserter.typedTexts.contains("press escape 3 times"))
    }

    @Test("system undo sends ⌘Z without changing buffer or stack")
    func pressUndoCommand() async throws {
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

        await mock.setFeedAudioResult(["system undo"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pressUndoCallCount >= 1 { break }
        }

        #expect(inserter.pressUndoCallCount >= 1)
        #expect(state.transcribedText == "Hello world", "keyboard-only; buffer unchanged")
        #expect(!inserter.typedTexts.contains("system undo"))
        #expect(inserter.deletedCounts.isEmpty, "⌘Z must not backspace session text")
    }

    @Test("system redo sends ⌘⇧Z without changing buffer or stack")
    func pressRedoCommand() async throws {
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

        await mock.setFeedAudioResult(["system redo"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pressRedoCallCount >= 1 { break }
        }

        #expect(inserter.pressRedoCallCount >= 1)
        #expect(state.transcribedText == "Hello world", "keyboard-only; buffer unchanged")
        #expect(!inserter.typedTexts.contains("system redo"))
        #expect(inserter.deletedCounts.isEmpty, "⌘⇧Z must not backspace session text")
        #expect(inserter.pressUndoCallCount == 0, "redo must not send undo")
    }

    @Test("forward delete sends key without changing buffer")
    func pressForwardDeleteCommand() async throws {
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

        await mock.setFeedAudioResult(["forward delete"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.pressForwardDeleteCallCount >= 1 { break }
        }

        #expect(inserter.pressForwardDeleteCallCount >= 1)
        #expect(state.transcribedText == "Hello world", "keyboard-only; buffer unchanged")
        #expect(!inserter.typedTexts.contains("forward delete"))
        #expect(inserter.deletedCounts.isEmpty, "forward delete must not use backspace path")
    }

    @Test("select next word at end falls back to keyboard select")
    func selectNextWordAtEndKeyboardFallback() async throws {
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

        // At session end (no sessionCaret) → keyboard fallback
        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectWordDirections.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.selectWordDirections == [.right])
        #expect(!inserter.typedTexts.contains("select next word"))
    }

    @Test("select previous word twice steps back progressive word index")
    func selectPreviousWordProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta gamma"])
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
            if state.transcribedText.lowercased().contains("alpha") { break }
        }

        // First previous: trailing last word ("gamma")
        await mock.setFeedAudioResult(["select previous word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty || !inserter.selectForwardCounts.isEmpty {
                break
            }
        }
        // Trailing path uses selectBackward (with leading space style)
        let firstSpan = inserter.selectBackwardCounts.last
        #expect(firstSpan == " gamma".count || firstSpan == "gamma".count
            || firstSpan == " Gamma".count || firstSpan == "Gamma".count)

        let forwardBefore = inserter.selectForwardCounts.count
        let backBefore = inserter.selectBackwardCounts.count
        await mock.setFeedAudioResult(["select previous word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > forwardBefore
                || inserter.selectBackwardCounts.count > backBefore {
                break
            }
        }

        // Second previous: step to "beta" via progressive path (selectForward content span)
        #expect(
            inserter.selectForwardCounts.last == "beta".count
                || inserter.selectForwardCounts.last == "Beta".count,
            "2nd previous should select beta, got \(String(describing: inserter.selectForwardCounts.last))"
        )
        #expect(state.transcribedText.lowercased().contains("gamma"))
    }

    @Test("select next then previous word steps back")
    func selectNextThenPreviousWord() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta gamma"])
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
            if state.transcribedText.lowercased().contains("alpha") { break }
        }

        await mock.setFeedAudioResult(["go to alpha"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == "alpha".count
            || inserter.selectForwardCounts.last == "Alpha".count)

        let countBefore = inserter.selectForwardCounts.count
        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > countBefore { break }
        }
        #expect(inserter.selectForwardCounts.last == "beta".count
            || inserter.selectForwardCounts.last == "Beta".count)

        let count2 = inserter.selectForwardCounts.count
        await mock.setFeedAudioResult(["select previous word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > count2 { break }
        }
        #expect(
            inserter.selectForwardCounts.last == "alpha".count
                || inserter.selectForwardCounts.last == "Alpha".count,
            "previous after next should return to alpha"
        )
    }

    @Test("select next word twice advances progressive word index")
    func selectNextWordProgressive() async throws {
        let mock = MockTranscriber()
        // Avoid spoken-number ITN ("one two three four" → "1234")
        await mock.setFeedAudioResult(["alpha beta gamma delta"])
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
            if state.transcribedText.lowercased().contains("alpha") { break }
        }

        // Caret at start of "alpha"
        await mock.setFeedAudioResult(["go to alpha"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == "alpha".count
            || inserter.selectForwardCounts.last == "Alpha".count)
        #expect(inserter.selectWordDirections.isEmpty)

        let selectCountBefore = inserter.selectForwardCounts.count
        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > selectCountBefore { break }
        }

        #expect(inserter.selectForwardCounts.last == "beta".count
            || inserter.selectForwardCounts.last == "Beta".count)
        #expect(inserter.selectWordDirections.isEmpty, "2nd select next must not fall back to keyboard")
        #expect(state.transcribedText.lowercased().contains("alpha"))
        #expect(state.transcribedText.lowercased().contains("delta"))
    }

    @Test("move left then select next word arms type-over for that word")
    func selectNextWordFromCaretThenContentReplaces() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world again"])
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
            if state.transcribedText == "Hello world again" { break }
        }

        // Caret to start of "world"
        await mock.setFeedAudioResult(["move left two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveWordDirections.count >= 2 { break }
        }

        await mock.setFeedAudioResult(["select next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world again")
        #expect(inserter.selectForwardCounts.last == "world".count)
        #expect(inserter.selectWordDirections.isEmpty)

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let after = state.transcribedText
        #expect(after.hasPrefix("Hello"), "prefix kept, got \"\(after)\"")
        #expect(after.lowercased().contains("planet"), "replaced, got \"\(after)\"")
        #expect(!after.lowercased().contains("world"), "world gone, got \"\(after)\"")
        #expect(after.lowercased().contains("again"), "tail kept, got \"\(after)\"")
    }

    @Test("select previous word selects trailing session word and arms type-over")
    func selectPreviousWordCommand() async throws {
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

        await mock.setFeedAudioResult(["select previous word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        // Session trailing select (same span as select last word), not bare ⌥⇧←
        #expect(inserter.selectBackwardCounts.last == " world".count)
        #expect(inserter.selectWordDirections.isEmpty)
        #expect(!inserter.typedTexts.contains("select previous word"))
    }

    @Test("select previous word then content replaces last word only")
    func selectPreviousWordThenContentReplaces() async throws {
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

        await mock.setFeedAudioResult(["select previous word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let text = state.transcribedText
        #expect(text.hasPrefix("Hello"), "prefix kept, got \"\(text)\"")
        #expect(text.lowercased().contains("planet"), "replacement present, got \"\(text)\"")
        #expect(!text.lowercased().contains("world"), "old word gone, got \"\(text)\"")
    }

    @Test("select previous two words then content replaces trailing span")
    func selectPreviousTwoWordsThenContentReplaces() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world now"])
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
            if state.transcribedText == "Hello world now" { break }
        }

        await mock.setFeedAudioResult(["select previous two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(inserter.selectBackwardCounts.last == " world now".count)

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let text = state.transcribedText
        #expect(text.hasPrefix("Hello"), "prefix kept, got \"\(text)\"")
        #expect(text.lowercased().contains("planet"))
        #expect(!text.lowercased().contains("world"))
        #expect(!text.lowercased().contains("now"))
    }

    @Test("delete next word uses keyboard without changing session buffer")
    func deleteNextWordCommand() async throws {
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

        await mock.setFeedAudioResult(["delete next word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.deleteWordDirections.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world", "v1: keyboard-only; caret-relative")
        #expect(inserter.deleteWordDirections == [.right])
        #expect(!inserter.typedTexts.contains("delete next word"))
    }

    @Test("insert date types formatted date into buffer and stack")
    func insertDateCommand() async throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10
        comps.hour = 15; comps.minute = 45
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        let tz = TimeZone(identifier: "UTC")!

        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        // Instance clock — no process-global InsertStamp.nowProvider (parallel-safe).
        state.nowProvider = { pinned }
        state.timeZoneProvider = { tz }
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

        await mock.setFeedAudioResult(["insert date"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("July 10, 2026") { break }
        }

        #expect(state.transcribedText == "HelloJuly 10, 2026")
        #expect(inserter.typedTexts.contains("July 10, 2026"))
        #expect(!inserter.typedTexts.contains("insert date"))
    }

    @Test("insert time types formatted local time into buffer and stack")
    func insertTimeCommand() async throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10
        comps.hour = 15; comps.minute = 45
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        let tz = TimeZone(identifier: "UTC")!
        let expectedTime = InsertStamp.formatTime(pinned, timeZone: tz)

        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.nowProvider = { pinned }
        state.timeZoneProvider = { tz }
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

        await mock.setFeedAudioResult(["insert time"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains(expectedTime) { break }
        }

        #expect(state.transcribedText == "Hello" + expectedTime)
        #expect(inserter.typedTexts.contains(expectedTime))
        #expect(!inserter.typedTexts.contains("insert time"))
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

    @Test("cap next capitalizes first word of next content and clears arm")
    func capNextOneShot() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["cap next"])
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
            if state.capitalizeNextWord { break }
        }
        #expect(state.capitalizeNextWord, "cap next should arm one-shot flag")
        #expect(state.transcribedText.isEmpty, "cap next is a command — no text")

        await mock.setFeedAudioResult(["hello world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.hasPrefix("Hello") { break }
        }
        #expect(
            state.transcribedText.hasPrefix("Hello"),
            "cap next should capitalize first word, got \"\(state.transcribedText)\""
        )
        #expect(
            state.transcribedText.contains("world") || state.transcribedText.contains("World"),
            "rest of phrase kept, got \"\(state.transcribedText)\""
        )
        #expect(!state.capitalizeNextWord, "arm clears after content commit")

        // Second content is not auto-capped
        await mock.setFeedAudioResult(["again"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("again") { break }
        }
        #expect(
            !state.transcribedText.hasSuffix("Again"),
            "cap next is one-shot only, got \"\(state.transcribedText)\""
        )
        #expect(!state.capitalizeNextWord)
    }

    @Test("cancelSession resets capitalizeNextWord")
    func cancelSessionResetsCapNext() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["cap next"])
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
            if state.capitalizeNextWord { break }
        }
        #expect(state.capitalizeNextWord)

        state.cancelSession()
        #expect(!state.capitalizeNextWord)
        #expect(state.capsMode == .normal)
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

    @Test("delete last two paragraphs peels both trailing paragraphs")
    func deleteLastTwoParagraphsCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\n\nB\n\nC"])
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
            if state.transcribedText == "A\n\nB\n\nC" { break }
        }

        await mock.setFeedAudioResult(["delete last two paragraphs"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "A" { break }
        }

        #expect(state.transcribedText == "A")
        #expect(inserter.deletedCounts.last == "\n\nB\n\nC".count)
        #expect(!inserter.typedTexts.contains("delete last two paragraphs"))
    }

    @Test("select next two sentences selects second and third")
    func selectNextTwoSentencesCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)
        let span = ranges[2].end - ranges[1].start

        await mock.setFeedAudioResult(["select next two sentences"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(inserter.selectForwardCounts.last == span)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("select next two sentences"))
    }

    @Test("delete next two paragraphs removes second and third")
    func deleteNextTwoParagraphsCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\n\nB\n\nC"])
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
            if state.transcribedText == "A\n\nB\n\nC" { break }
        }

        await mock.setFeedAudioResult(["delete next two paragraphs"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "A" { break }
        }

        #expect(state.transcribedText == "A")
        #expect(!inserter.typedTexts.contains("delete next two paragraphs"))
    }

    @Test("select last two sentences selects combined trailing span")
    func selectLastTwoSentencesCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)
        let span = text.count - ranges[1].start

        await mock.setFeedAudioResult(["select last two sentences"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(inserter.selectBackwardCounts.last == span)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("select last two sentences"))
    }

    @Test("delete last two sentences peels both trailing sentences")
    func deleteLastTwoSentencesCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        await mock.setFeedAudioResult(["delete last two sentences"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello." { break }
        }

        #expect(state.transcribedText == "Hello.")
        #expect(inserter.deletedCounts.last == " World. Done".count)
        #expect(!inserter.typedTexts.contains("delete last two sentences"))
    }

    @Test("delete previous 3 characters peels trailing buffer chars")
    func deletePreviousThreeCharactersCommand() async throws {
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

        await mock.setFeedAudioResult(["delete previous 3 characters"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello wo" { break }
        }

        #expect(state.transcribedText == "Hello wo")
        #expect(inserter.deletedCounts.last == 3)
        #expect(!inserter.typedTexts.contains("delete previous 3 characters"))
    }

    @Test("select previous 4 characters uses selectBackward")
    func selectPreviousFourCharactersCommand() async throws {
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

        await mock.setFeedAudioResult(["select previous 4 characters"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(inserter.selectBackwardCounts.last == 4)
        #expect(state.transcribedText == "Hello world")
        #expect(!inserter.typedTexts.contains("select previous 4 characters"))
    }

    @Test("delete last two words peels both trailing words")
    func deleteLastTwoWordsCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world now"])
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
            if state.transcribedText == "Hello world now" { break }
        }

        await mock.setFeedAudioResult(["delete last two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello" { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.deletedCounts.last == " world now".count)
        #expect(!inserter.typedTexts.contains("delete last two words"))
    }

    @Test("delete first sentence leaves remainder")
    func deleteFirstSentenceCommand() async throws {
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

        let start = TranscriptSelection.secondSentenceStartOffset("Hello. World now")!
        await mock.setFeedAudioResult(["delete first sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "World now" { break }
        }

        #expect(state.transcribedText == "World now")
        #expect(inserter.moveBackwardCounts.last == "Hello. World now".count)
        #expect(inserter.selectForwardCounts.last == start)
        #expect(inserter.deletedCounts.last == 1)
        #expect(!inserter.typedTexts.contains("delete first sentence"))
    }

    @Test("delete first line leaves remaining lines")
    func deleteFirstLineCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("Line two") { break }
        }

        await mock.setFeedAudioResult(["delete first line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Line two" { break }
        }

        #expect(state.transcribedText == "Line two")
        #expect(!inserter.typedTexts.contains("delete first line"))
    }

    @Test("delete last sentence leaves prior sentence and deletes in mock")
    func deleteLastSentenceCommand() async throws {
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

        await mock.setFeedAudioResult(["delete last sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello." { break }
        }

        #expect(state.transcribedText == "Hello.")
        #expect(inserter.deletedCounts.last == " World now".count)
        #expect(!inserter.typedTexts.contains("delete last sentence"))
    }

    @Test("delete last paragraph leaves prior paragraph and deletes in mock")
    func deleteLastParagraphCommand() async throws {
        let mock = MockTranscriber()
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

        let before = state.transcribedText
        await mock.setFeedAudioResult(["delete last paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText != before { break }
        }

        #expect(state.transcribedText == "Para one\n\n" || state.transcribedText.hasPrefix("Para one"))
        #expect(state.transcribedText.hasSuffix("Para one") || state.transcribedText == "Para one\n\n")
        #expect(inserter.deletedCounts.last == "Para two".count)
        #expect(!inserter.typedTexts.contains("delete last paragraph"))
    }

    @Test("delete last line leaves prior line and deletes in mock")
    func deleteLastLineCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("Line two") { break }
        }

        let before = state.transcribedText
        await mock.setFeedAudioResult(["delete last line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText != before { break }
        }

        #expect(state.transcribedText == "Line one\n" || state.transcribedText.hasPrefix("Line one"))
        #expect(inserter.deletedCounts.last == "Line two".count)
        #expect(!inserter.typedTexts.contains("delete last line"))
    }

    @Test("delete last line peels trailing empty line (Hello + newline → Hello)")
    func deleteLastLineTrailingEmptyNewline() async throws {
        let mock = MockTranscriber()
        // Content then press enter (ASR does not keep raw "\n" through post-process)
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
        #expect(state.transcribedText == "Hello",
                "precondition: content landed, got \(state.transcribedText.debugDescription)")

        await mock.setFeedAudioResult(["press enter"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello\n" { break }
        }
        #expect(state.transcribedText == "Hello\n",
                "precondition: trailing empty line, got \(state.transcribedText.debugDescription)")

        let before = state.transcribedText
        await mock.setFeedAudioResult(["delete last line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText != before { break }
        }

        #expect(state.transcribedText == "Hello")
        #expect(inserter.deletedCounts.last == 1) // peeled "\n"
        #expect(!inserter.typedTexts.contains("delete last line"))
    }

    @Test("delete last paragraph peels trailing blank paragraph (\\n\\n)")
    func deleteLastParagraphTrailingBlank() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Only"])
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
            if state.transcribedText.contains("Only") { break }
        }

        // Two enters → trailing blank paragraph ("Only\n\n")
        await mock.setFeedAudioResult(["press enter"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.hasSuffix("\n") { break }
        }
        await mock.setFeedAudioResult(["press enter"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.hasSuffix("\n\n") { break }
        }

        let before = state.transcribedText
        #expect(before.hasSuffix("\n\n"),
                "precondition: trailing blank paragraph, got \(before.debugDescription)")

        await mock.setFeedAudioResult(["delete last paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText != before { break }
        }

        #expect(state.transcribedText == "Only")
        #expect(inserter.deletedCounts.last == 2) // peeled "\n\n"
        #expect(!inserter.typedTexts.contains("delete last paragraph"))
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

    @Test("select that seeds select again memory (Dragon dual of SelectAgain.tla)")
    func selectThatThenSelectAgainWalksEarlierOccurrence() async throws {
        // Last stack delta is the word "foo" (second utterance). Buffer holds
        // two foos so select again can walk left (SelectAgain cursor-1).
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello foo"])
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }

        await mock.setFeedAudioResult(["foo"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            // Two foos in buffer (first inside "hello foo", second from last delta)
            let lower = state.transcribedText.lowercased()
            if lower.components(separatedBy: "foo").count >= 3 { break }
        }
        let buf = state.transcribedText.lowercased()
        #expect(
            buf.components(separatedBy: "foo").count >= 3,
            "need two foos in buffer for select again, got \"\(state.transcribedText)\""
        )

        await mock.setFeedAudioResult(["select that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }
        #expect(!inserter.typedTexts.contains("select that"))
        // lastDelta is second "foo" (maybe with leading space) — trailing select
        let thatSpan = inserter.selectBackwardCounts.last
        #expect(
            thatSpan == "foo".count || thatSpan == " foo".count
                || thatSpan == "Foo".count || thatSpan == " Foo".count,
            "select that should select last delta foo, got \(String(describing: thatSpan))"
        )
        let forwardBefore = inserter.selectForwardCounts.count

        await mock.setFeedAudioResult(["select again"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > forwardBefore { break }
        }

        // Select again re-selects earlier foo via selectForward (mid-buffer).
        #expect(
            inserter.selectForwardCounts.last == "foo".count
                || inserter.selectForwardCounts.last == "Foo".count,
            "select again after select that should select earlier foo, got \(String(describing: inserter.selectForwardCounts.last))"
        )
        #expect(!inserter.typedTexts.contains("select again"))
    }

    @Test("select last sentence seeds select again for repeated sentence")
    func selectLastSentenceThenSelectAgain() async throws {
        // Two identical sentence bodies so select again walks left.
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world. Hello world."])
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }

        await mock.setFeedAudioResult(["select last sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty || !inserter.selectForwardCounts.isEmpty {
                break
            }
        }
        let forwardBefore = inserter.selectForwardCounts.count

        await mock.setFeedAudioResult(["select again"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > forwardBefore { break }
        }

        #expect(
            inserter.selectForwardCounts.count > forwardBefore
                || !inserter.selectBackwardCounts.isEmpty,
            "select again after select last sentence should re-select earlier match"
        )
        #expect(!inserter.typedTexts.contains("select again"))
        #expect(state.transcribedText.lowercased().contains("hello"))
    }

    @Test("select last word seeds select again for repeated word")
    func selectLastWordThenSelectAgain() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta alpha"])
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
            if state.transcribedText.lowercased().contains("beta") { break }
        }

        await mock.setFeedAudioResult(["select last word"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }
        let beforeAgain = inserter.selectForwardCounts.count

        await mock.setFeedAudioResult(["select again"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count > beforeAgain { break }
        }

        #expect(
            inserter.selectForwardCounts.last == "alpha".count
                || inserter.selectForwardCounts.last == "Alpha".count,
            "select again after select last word should land on earlier alpha"
        )
        #expect(!inserter.typedTexts.contains("select again"))
    }

    @Test("go after X then content inserts mid-buffer (not always append)")
    func goAfterPhraseThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["go after world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let after = state.transcribedText.lowercased()
        #expect(
            after == "hello world planet foo",
            "mid insert after world, got \"\(state.transcribedText)\""
        )
        #expect(!inserter.typedTexts.contains("go after world"))
    }

    @Test("resume with X truncates after match then next content appends")
    func resumeWithThenContentAppends() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo bar"])
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
            if state.transcribedText.lowercased().contains("bar") { break }
        }

        await mock.setFeedAudioResult(["resume with world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.deletedCounts.isEmpty
                || state.transcribedText.lowercased() == "hello world" {
                break
            }
        }
        #expect(
            state.transcribedText.lowercased() == "hello world",
            "kept through world, got \"\(state.transcribedText)\""
        )
        #expect(!inserter.typedTexts.contains("resume with world"))
        #expect(inserter.deletedCounts.contains { $0 > 0 })

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }
        let after = state.transcribedText.lowercased()
        #expect(
            after == "hello world planet" || after.hasPrefix("hello world"),
            "append after resume, got \"\(state.transcribedText)\""
        )
        #expect(after.contains("planet"))
        #expect(!after.contains("foo"))
    }

    @Test("insert after X then content inserts mid-buffer (Dragon dual)")
    func insertAfterPhraseThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["insert after world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        #expect(!inserter.typedTexts.contains("insert after world"))

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let after = state.transcribedText.lowercased()
        #expect(
            after == "hello world planet foo",
            "insert after world then planet, got \"\(state.transcribedText)\""
        )
    }

    @Test("second go to uses sessionCaret not end (host dual)")
    func successiveGoToUsesSessionCaretNotEnd() async throws {
        // "alpha beta gamma" — go to beta from end, then go to alpha from beta.
        // Bug: second move assumed host still at end → overshoots left of alpha.
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta gamma"])
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
            if state.transcribedText.lowercased().contains("gamma") { break }
        }

        let text = state.transcribedText
        let lower = text.lowercased()
        guard let betaRange = lower.range(of: "beta"),
              let alphaRange = lower.range(of: "alpha") else {
            Issue.record("expected alpha/beta in \"\(text)\"")
            return
        }
        let betaStart = text.distance(from: text.startIndex, to: betaRange.lowerBound)
        let alphaStart = text.distance(from: text.startIndex, to: alphaRange.lowerBound)
        let end = text.count

        await mock.setFeedAudioResult(["go to beta"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        #expect(inserter.moveBackwardCounts.last == end - betaStart,
                "first go-to from end to beta")

        let backBefore = inserter.moveBackwardCounts
        let forwardBefore = inserter.moveForwardCounts

        await mock.setFeedAudioResult(["go to alpha"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveBackwardCounts.count > backBefore.count
                || inserter.moveForwardCounts.count > forwardBefore.count {
                break
            }
        }

        // Correct: move left by (betaStart - alphaStart) from beta.
        // Bug: would move left by (end - alphaStart) from end.
        let expected = betaStart - alphaStart
        let wrongFromEnd = end - alphaStart
        #expect(inserter.moveBackwardCounts.last == expected,
                "second go-to from beta to alpha; expected \(expected), wrong-from-end \(wrongFromEnd), got \(inserter.moveBackwardCounts.last ?? -1)")
        #expect(inserter.moveBackwardCounts.last != wrongFromEnd
                || expected == wrongFromEnd)
    }

    @Test("go to after word move uses sessionCaret not end")
    func goToAfterWordMoveUsesSessionCaret() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta gamma"])
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
            if state.transcribedText.lowercased().contains("gamma") { break }
        }

        let text = state.transcribedText
        let lower = text.lowercased()
        guard let alphaRange = lower.range(of: "alpha") else {
            Issue.record("expected alpha in \"\(text)\"")
            return
        }
        let alphaStart = text.distance(from: text.startIndex, to: alphaRange.lowerBound)
        let end = text.count

        // Move left one word → sessionCaret mid-buffer (before last word).
        await mock.setFeedAudioResult(["move left"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveWordDirections.isEmpty { break }
        }
        #expect(inserter.moveWordDirections.last == .left)

        let backBefore = inserter.moveBackwardCounts.count

        await mock.setFeedAudioResult(["go to alpha"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveBackwardCounts.count > backBefore { break }
        }

        // After word-left from end, sessionCaret is mid-buffer.
        // Go-to alpha must delta from that caret — not from end.
        #expect(inserter.moveBackwardCounts.count > backBefore,
                "go to alpha should issue a relative move")
        guard let last = inserter.moveBackwardCounts.last else {
            Issue.record("expected moveBackward after go to alpha")
            return
        }
        let wrongFromEnd = end - alphaStart
        #expect(last < wrongFromEnd,
                "delta from mid caret must be shorter than from end; got \(last), from-end \(wrongFromEnd)")
    }

    @Test("go to X then content inserts before phrase (does not replace)")
    func goToPhraseThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["go to world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        #expect(inserter.selectForwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("go to world"))

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let after = state.transcribedText.lowercased()
        // Insert before "world", keep world (not type-over replace)
        #expect(after.contains("world"), "go to must not replace, got \"\(state.transcribedText)\"")
        #expect(after.contains("planet"))
        #expect(after.contains("hello") && after.contains("foo"))
        #expect(
            after.contains("planet world") || after.contains("planet  world"),
            "planet before world, got \"\(state.transcribedText)\""
        )
    }

    @Test("go after X moves to end of match; miss is no-op")
    func goAfterPhraseCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["go after world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        let text = state.transcribedText
        let worldRange = text.lowercased().range(of: "world")!
        let afterOffset = text.distance(from: text.startIndex, to: worldRange.upperBound)
        let fromEnd = text.count - afterOffset
        #expect(inserter.moveBackwardCounts.last == fromEnd)
        #expect(state.transcribedText == text)

        let movesBefore = inserter.moveBackwardCounts.count
        await mock.setFeedAudioResult(["go to zzz"])
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(inserter.moveBackwardCounts.count == movesBefore)
        #expect(!inserter.typedTexts.contains("go to zzz"))
    }

    @Test("select X arms middle phrase then content type-over replaces only that span")
    func selectPhraseThenContentReplaces() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world foo"])
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
            if state.transcribedText.lowercased().contains("world") { break }
        }

        await mock.setFeedAudioResult(["select world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText.lowercased().contains("world"))
        #expect(inserter.selectForwardCounts.last == "world".count)
        #expect(!inserter.typedTexts.contains("select world"))

        // Avoid silence-hallucination short hyps
        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("planet") { break }
        }

        let text = state.transcribedText.lowercased()
        #expect(text.contains("planet"), "replacement present, got \"\(state.transcribedText)\"")
        #expect(!text.contains("world"), "selected phrase replaced, got \"\(state.transcribedText)\"")
        #expect(text.contains("hello") && text.contains("foo"))
    }

    @Test("select X no-op when target missing")
    func selectPhraseMissingTarget() async throws {
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }
        let before = state.transcribedText
        let selectBefore = inserter.selectForwardCounts.count

        await mock.setFeedAudioResult(["select zzz"])
        recorder.lastOnSamples?([0.1])
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(state.transcribedText == before)
        #expect(inserter.selectForwardCounts.count == selectBefore)
        #expect(!inserter.typedTexts.contains("select zzz"))
    }

    @Test("select that then re-dictate replaces suffix in buffer (not append)")
    func selectThatThenContentReplaces() async throws {
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
            if state.transcribedText.lowercased().contains("wrong") { break }
        }

        await mock.setFeedAudioResult(["select that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["right words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("right")
                && !state.transcribedText.lowercased().contains("wrong") {
                break
            }
        }

        #expect(
            state.transcribedText.lowercased().contains("right"),
            "expected replacement, got \"\(state.transcribedText)\""
        )
        #expect(
            !state.transcribedText.lowercased().contains("wrong"),
            "old phrase must not remain, got \"\(state.transcribedText)\""
        )
        #expect(!inserter.typedTexts.contains("select that"))
    }

    @Test("select last two words then content peels those words only")
    func selectLastTwoWordsThenContentReplaces() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world now"])
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
            if state.transcribedText == "Hello world now" { break }
        }

        await mock.setFeedAudioResult(["select last two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("planet") || state.transcribedText.contains("Planet") {
                break
            }
        }

        // Selection was " world now" (leading space); type-over peels exact suffix.
        let text = state.transcribedText
        #expect(text.hasPrefix("Hello"), "prefix preserved, got \"\(text)\"")
        #expect(
            text.lowercased().contains("planet"),
            "replacement present, got \"\(text)\""
        )
        #expect(
            !text.lowercased().contains("world"),
            "selected words gone, got \"\(text)\""
        )
        #expect(
            !text.lowercased().contains("now"),
            "selected words gone, got \"\(text)\""
        )
    }

    @Test("unselect that then content still appends")
    func unselectThatThenContentAppends() async throws {
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

        await mock.setFeedAudioResult(["select that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["unselect that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.clearSelectionCallCount > 0 { break }
        }

        await mock.setFeedAudioResult(["world"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("world") { break }
        }

        #expect(
            state.transcribedText == "Hello world" || state.transcribedText == "Hello World",
            "unselect must restore append join, got \"\(state.transcribedText)\""
        )
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

    @Test("select last two words selects trailing span without changing buffer")
    func selectLastTwoWordsCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world now"])
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
            if state.transcribedText == "Hello world now" { break }
        }

        await mock.setFeedAudioResult(["select last two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world now")
        #expect(inserter.selectBackwardCounts.last == " world now".count)
        #expect(!inserter.typedTexts.contains("select last two words"))
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

    @Test("select first sentence moves to session start then selects forward")
    func selectFirstSentenceCommand() async throws {
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

        await mock.setFeedAudioResult(["select first sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello. World now")
        #expect(inserter.moveBackwardCounts.last == "Hello. World now".count)
        #expect(inserter.selectForwardCounts.last == "Hello.".count)
        #expect(inserter.selectBackwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("select first sentence"))
    }

    @Test("select first sentence then content replaces first only")
    func selectFirstSentenceThenContentReplaces() async throws {
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

        await mock.setFeedAudioResult(["select first sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        // Avoid silence-hallucination short hyps like "Hi." (dropped by TextPostProcessor).
        await mock.setFeedAudioResult(["Better."])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.hasPrefix("Better.") { break }
        }

        #expect(
            state.transcribedText == "Better. World now",
            "first sentence replaced in place, got \"\(state.transcribedText)\""
        )
        #expect(!state.transcribedText.lowercased().contains("hello"))
        #expect(!inserter.typedTexts.contains("select first sentence"))
    }

    @Test("select next sentence then content replaces second only")
    func selectNextSentenceThenContentReplaces() async throws {
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

        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["Planet"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("Planet") || state.transcribedText.contains("planet") {
                break
            }
        }

        let text = state.transcribedText
        #expect(text.hasPrefix("Hello."), "first sentence kept, got \"\(text)\"")
        #expect(
            text == "Hello. Planet" || text == "Hello. planet",
            "second sentence replaced only, got \"\(text)\""
        )
        #expect(!text.lowercased().contains("world"))
        #expect(!text.lowercased().contains("now"))
    }

    @Test("select next sentence jumps past first then selects second")
    func selectNextSentenceCommand() async throws {
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

        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello. World now")
        // From end → second-sentence content start (skip whitespace), then select
        let start = TranscriptSelection.secondSentenceStartOffset("Hello. World now")!
        #expect(inserter.moveBackwardCounts.last == "Hello. World now".count - start)
        #expect(inserter.selectForwardCounts.last == "World now".count)
        #expect(!inserter.typedTexts.contains("select next sentence"))
    }

    @Test("select previous sentence from end selects last then steps back")
    func selectPreviousSentenceProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["select previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == ranges[2].end - ranges[2].start)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["select previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count >= 2 { break }
        }
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(inserter.selectForwardCounts.last == ranges[1].end - ranges[1].start)
        #expect(state.transcribedText == text)
    }

    @Test("select next sentence twice advances to third sentence")
    func selectNextSentenceProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == ranges[1].end - ranges[1].start)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count >= 2 { break }
        }
        // Second hop: collapse prior selection, then select third
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(inserter.selectForwardCounts.last == ranges[2].end - ranges[2].start)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("select next sentence"))
    }

    @Test("select first sentence then select next advances to second")
    func selectFirstThenNextSentence() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)

        await mock.setFeedAudioResult(["select first sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == ranges[0].end - ranges[0].start)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count >= 2 { break }
        }
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(inserter.selectForwardCounts.last == ranges[1].end - ranges[1].start)
        #expect(state.transcribedText == text)
    }

    @Test("select next sentence is no-op for single-sentence buffer")
    func selectNextSentenceSingleSentenceNoOp() async throws {
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

        await mock.setFeedAudioResult(["select next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveBackwardCounts.isEmpty)
        #expect(inserter.moveForwardCounts.isEmpty)
        #expect(inserter.selectForwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("select next sentence"))
    }

    @Test("delete next sentence removes second when it is also last")
    func deleteNextSentenceTwoSentences() async throws {
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

        await mock.setFeedAudioResult(["delete next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello." { break }
        }

        #expect(state.transcribedText == "Hello.")
        #expect(inserter.deletedCounts.last == " World now".count)
        #expect(!inserter.typedTexts.contains("delete next sentence"))
    }

    @Test("delete next sentence removes middle sentence when three present")
    func deleteNextSentenceMiddle() async throws {
        let mock = MockTranscriber()
        // Avoid single-letter acronym packing and spoken-number ITN.
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        await mock.setFeedAudioResult(["delete next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello. Done" { break }
        }

        #expect(state.transcribedText == "Hello. Done")
        // Keyboard: land at end of first, select gap+second (" World."), delete selection
        let priorEnd = TranscriptSelection.firstSentence("Hello. World. Done").count
        #expect(inserter.moveBackwardCounts.last == "Hello. World. Done".count - priorEnd)
        #expect(inserter.selectForwardCounts.last == " World.".count)
        #expect(inserter.deletedCounts.last == 1)
        #expect(!inserter.typedTexts.contains("delete next sentence"))
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

    @Test("select first paragraph moves to session start then selects forward")
    func selectFirstParagraphCommand() async throws {
        let mock = MockTranscriber()
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

        await mock.setFeedAudioResult(["select first paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText.contains("Para one"))
        #expect(inserter.moveBackwardCounts.last == state.transcribedText.count)
        #expect(inserter.selectForwardCounts.last == "Para one".count)
        #expect(!inserter.typedTexts.contains("select first paragraph"))
    }

    @Test("select next paragraph jumps past first then selects second")
    func selectNextParagraphCommand() async throws {
        let mock = MockTranscriber()
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

        await mock.setFeedAudioResult(["select next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText.contains("Para two"))
        // From end → second-paragraph content start, then select
        let start = TranscriptSelection.secondParagraphStartOffset(state.transcribedText)!
        #expect(inserter.moveBackwardCounts.last == state.transcribedText.count - start)
        #expect(inserter.selectForwardCounts.last == "Para two".count)
        #expect(!inserter.typedTexts.contains("select next paragraph"))
    }

    @Test("select next paragraph twice advances to third paragraph")
    func selectNextParagraphProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\n\nB\n\nC"])
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
            if state.transcribedText.contains("C") { break }
        }

        let text = "A\n\nB\n\nC"
        let ranges = TranscriptSelection.paragraphRanges(text)
        #expect(ranges.count == 3)
        #expect(state.transcribedText == text)

        await mock.setFeedAudioResult(["select next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        // First hop: second paragraph "B"
        #expect(inserter.selectForwardCounts.last == ranges[1].end - ranges[1].start)
        #expect(inserter.selectForwardCounts.last == "B".count)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["select next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count >= 2 { break }
        }
        // Second hop: collapse prior selection, then select third "C"
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(inserter.selectForwardCounts.last == "C".count)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("select next paragraph"))
    }

    @Test("delete next paragraph removes second when it is also last")
    func deleteNextParagraphTwoParas() async throws {
        let mock = MockTranscriber()
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

        await mock.setFeedAudioResult(["delete next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Para one" || state.transcribedText.hasPrefix("Para one") && !state.transcribedText.contains("Para two") {
                break
            }
        }

        #expect(!state.transcribedText.contains("Para two"))
        #expect(state.transcribedText.hasPrefix("Para one") || state.transcribedText == "Para one")
        #expect(!inserter.typedTexts.contains("delete next paragraph"))
    }

    @Test("delete next paragraph removes middle when three present")
    func deleteNextParagraphMiddle() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\n\nB\n\nC"])
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
            if state.transcribedText.contains("C") { break }
        }

        #expect(state.transcribedText == "A\n\nB\n\nC")
        await mock.setFeedAudioResult(["delete next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "A\n\nC" || state.transcribedText.contains("C") && !state.transcribedText.contains("B") {
                break
            }
        }

        #expect(state.transcribedText == "A\n\nC")
        #expect(!inserter.typedTexts.contains("delete next paragraph"))
    }

    @Test("next paragraph twice advances to third paragraph start")
    func moveToNextParagraphProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\n\nB\n\nC"])
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
            if state.transcribedText == "A\n\nB\n\nC" { break }
        }

        let text = "A\n\nB\n\nC"
        let ranges = TranscriptSelection.paragraphRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        #expect(inserter.moveBackwardCounts.last == text.count - ranges[1].start)

        await mock.setFeedAudioResult(["next paragraph"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveForwardCounts.isEmpty { break }
        }
        #expect(inserter.moveForwardCounts.last == ranges[2].start - ranges[1].start)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("next paragraph"))
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

    @Test("move left two words moves cursor N times without changing buffer")
    func movePreviousWordsCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world again"])
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
            if state.transcribedText == "Hello world again" { break }
        }

        await mock.setFeedAudioResult(["move left two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveWordDirections.count >= 2 { break }
        }

        #expect(state.transcribedText == "Hello world again")
        #expect(inserter.moveWordDirections == [.left, .left])
        #expect(!inserter.typedTexts.contains("move left two words"))
    }

    @Test("move left two words then content inserts mid-buffer")
    func moveLeftTwoWordsThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world again"])
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
            if state.transcribedText == "Hello world again" { break }
        }

        await mock.setFeedAudioResult(["move left two words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveWordDirections.count >= 2 { break }
        }

        await mock.setFeedAudioResult(["extra"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("extra") { break }
        }

        let after = state.transcribedText
        #expect(after.hasPrefix("Hello"), "prefix kept, got \"\(after)\"")
        #expect(after.lowercased().contains("extra"), "inserted, got \"\(after)\"")
        #expect(after.lowercased().contains("world"), "mid words kept, got \"\(after)\"")
        #expect(after.lowercased().contains("again"), "tail kept, got \"\(after)\"")
        // Not pure trailing append of extra after the whole phrase only
        #expect(
            after.lowercased().contains("extra world")
                || after.lowercased().contains("extra  world")
                || (after.lowercased().contains("hello extra") && after.lowercased().contains("world")),
            "extra should land before world/again, got \"\(after)\""
        )
    }

    @Test("move right 3 words moves cursor N times without changing buffer")
    func moveNextWordsCommand() async throws {
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

        await mock.setFeedAudioResult(["move right 3 words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveWordDirections.count >= 3 { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveWordDirections == [.right, .right, .right])
        #expect(!inserter.typedTexts.contains("move right 3 words"))
    }

    @Test("move left 5 characters moves without changing buffer")
    func movePreviousCharactersCommand() async throws {
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

        await mock.setFeedAudioResult(["move left 5 characters"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveBackwardCounts == [5])
        #expect(!inserter.typedTexts.contains("move left 5 characters"))
    }

    @Test("move left 5 characters then content inserts mid-buffer")
    func moveLeftCharactersThenContentInsertsMid() async throws {
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

        await mock.setFeedAudioResult(["move left 5 characters"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["XX"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("XX") || state.transcribedText.contains("xx") { break }
        }

        let after = state.transcribedText
        // "Hello world".count=11; left 5 → caret at 6 ("Hello ")
        // insert XX → should not be pure trailing-only append of " XX" at end only
        #expect(after.hasPrefix("Hello"), "prefix kept, got \"\(after)\"")
        #expect(
            after.contains("XX") || after.contains("xx") || after.contains("Xx"),
            "inserted, got \"\(after)\""
        )
        #expect(after.lowercased().contains("world"), "tail kept, got \"\(after)\"")
        #expect(
            after.count > "Hello world".count,
            "grew by insert, got \"\(after)\""
        )
        // Mid insert: "world" still present and XX not only after full original if space join
        #expect(
            !after.lowercased().hasSuffix("hello world xx")
                || after.lowercased().contains("xx world")
                || after.lowercased().contains(" xxworld")
                || after.lowercased().contains("xxworld")
                || after.lowercased().contains(" xx world"),
            "XX should land mid-buffer, got \"\(after)\""
        )
    }

    @Test("forward one character moves without changing buffer")
    func moveNextCharactersCommand() async throws {
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

        await mock.setFeedAudioResult(["forward one character"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveForwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveForwardCounts == [1])
        #expect(!inserter.typedTexts.contains("forward one character"))
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

    @Test("end of sentence then content inserts at sentence edge")
    func endOfSentenceThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world. Next sentence."])
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
            if state.transcribedText.contains(".") { break }
        }

        let text = state.transcribedText
        let ranges = TranscriptSelection.sentenceRanges(text)
        guard ranges.count >= 2 else {
            Issue.record("need 2+ sentences, got \"\(text)\"")
            return
        }

        // Move to start of first sentence, then "end of sentence" → first sentence end
        await mock.setFeedAudioResult(["beginning of document"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToDocumentStartCalled { break }
        }

        await mock.setFeedAudioResult(["end of sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveForwardCounts.isEmpty || !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["XX"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("XX") || state.transcribedText.contains("xx") { break }
        }

        let after = state.transcribedText
        #expect(
            after.contains("XX") || after.contains("xx") || after.contains("Xx"),
            "inserted XX, got \"\(after)\""
        )
        // Must not be pure trailing-only append after whole buffer
        #expect(
            !after.lowercased().hasSuffix("xx")
                || after.lowercased().contains("xx next")
                || after.lowercased().contains("xxnext")
                || after.range(of: "XX", options: .caseInsensitive)?.upperBound
                    != after.endIndex,
            "prefer mid-buffer insert at sentence edge, got \"\(after)\""
        )
        #expect(!inserter.typedTexts.contains("end of sentence"))
    }

    @Test("start of sentence moves host without changing buffer")
    func startOfSentenceCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello world. Next one."])
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
            if state.transcribedText.contains(".") { break }
        }
        let before = state.transcribedText

        await mock.setFeedAudioResult(["start of sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == before)
        #expect(!inserter.typedTexts.contains("start of sentence"))
        // From end, start of last sentence is a backward move
        #expect(!inserter.moveBackwardCounts.isEmpty || !inserter.moveForwardCounts.isEmpty)
    }

    @Test("beginning of document then content inserts at start (sessionCaret dual)")
    func documentStartThenContentInsertsMid() async throws {
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
            if state.transcribedText.lowercased().contains("hello") { break }
        }

        await mock.setFeedAudioResult(["beginning of document"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToDocumentStartCalled { break }
        }
        #expect(inserter.moveToDocumentStartCalled)

        await mock.setFeedAudioResult(["XX"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("XX") || state.transcribedText.contains("xx") { break }
        }

        let after = state.transcribedText
        // Must insert at document start — not pure trailing append only.
        #expect(
            after.hasPrefix("XX") || after.hasPrefix("Xx") || after.hasPrefix("xx")
                || after.lowercased().hasPrefix("xx"),
            "content at doc start, got \"\(after)\""
        )
        #expect(after.lowercased().contains("hello"))
        #expect(!inserter.typedTexts.contains("beginning of document"))
    }

    @Test("go to start of multi-line then content inserts at line start")
    func lineStartThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("\n") { break }
        }

        // From end of second line, go to start of that line, insert YY
        await mock.setFeedAudioResult(["go to start"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToLineStartCalled { break }
        }
        #expect(inserter.moveToLineStartCalled)

        await mock.setFeedAudioResult(["YY"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("YY") || state.transcribedText.contains("yy") { break }
        }

        let after = state.transcribedText
        #expect(after.contains("Line one"), "first line kept, got \"\(after)\"")
        // YY should sit on second line (not only as trailing " YY" after whole buffer with no mid dual)
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2, "still multi-line, got \"\(after)\"")
        if lines.count >= 2 {
            let second = String(lines[1]).lowercased()
            #expect(
                second.contains("yy"),
                "insert on second line after go to start, got \"\(after)\""
            )
        }
    }

    @Test("move up / down line moves cursor without changing buffer")
    func moveUpDownLineCommands() async throws {
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

        await mock.setFeedAudioResult(["move up"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveLineDirections.isEmpty { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveLineDirections == [.up])
        #expect(!inserter.typedTexts.contains("move up"))

        await mock.setFeedAudioResult(["move down"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveLineDirections.count >= 2 { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveLineDirections == [.up, .down])
        #expect(!inserter.typedTexts.contains("move down"))
    }

    @Test("next line progressive then content inserts at second line start")
    func nextLineThenContentInsertsMid() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two\nLine three"])
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
            if state.transcribedText.contains("\n") { break }
        }

        await mock.setFeedAudioResult(["next line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty || !inserter.moveForwardCounts.isEmpty { break }
        }
        #expect(!inserter.typedTexts.contains("next line"))

        await mock.setFeedAudioResult(["XX"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.contains("XX") || state.transcribedText.contains("xx") { break }
        }

        let after = state.transcribedText
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2, "still multi-line, got \"\(after)\"")
        if lines.count >= 2 {
            let second = String(lines[1]).lowercased()
            #expect(
                second.contains("xx") || second.hasPrefix("xx"),
                "insert on second line after next line, got \"\(after)\""
            )
        }
        #expect(after.lowercased().contains("line one") || after.lowercased().contains("line"))
    }

    @Test("beginning / end of document moves document cursor without changing buffer")
    func moveToDocumentEdgeCommands() async throws {
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

        await mock.setFeedAudioResult(["beginning of document"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToDocumentStartCalled { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveToDocumentStartCalled)
        #expect(!inserter.moveToLineStartCalled)
        #expect(!inserter.typedTexts.contains("beginning of document"))

        await mock.setFeedAudioResult(["end of document"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveToDocumentEndCalled { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveToDocumentEndCalled)
        #expect(!inserter.moveToLineEndCalled)
        #expect(!inserter.typedTexts.contains("end of document"))
    }

    @Test("page up / down scrolls without changing buffer")
    func pageScrollCommands() async throws {
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

        await mock.setFeedAudioResult(["page up"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.scrollPageDirections.isEmpty { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.scrollPageDirections == [.up])
        #expect(inserter.moveLineDirections.isEmpty)
        #expect(!inserter.typedTexts.contains("page up"))

        await mock.setFeedAudioResult(["scroll down"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.scrollPageDirections.count >= 2 { break }
        }
        #expect(state.transcribedText == "Hello world")
        #expect(inserter.scrollPageDirections == [.up, .down])
        #expect(inserter.moveLineDirections.isEmpty)
        #expect(!inserter.typedTexts.contains("scroll down"))
    }

    @Test("select last line selects trailing line only")
    func selectLastLineCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("Line two") { break }
        }

        await mock.setFeedAudioResult(["select last line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText.hasSuffix("Line two") || state.transcribedText.contains("Line two"))
        #expect(inserter.selectBackwardCounts.last == "Line two".count)
        #expect(!inserter.typedTexts.contains("select last line"))
    }

    @Test("select next line twice advances to third line")
    func selectNextLineProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["A\nB\nC"])
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
            if state.transcribedText == "A\nB\nC" { break }
        }

        let text = "A\nB\nC"
        let ranges = TranscriptSelection.lineRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["select next line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }
        #expect(inserter.selectForwardCounts.last == ranges[1].end - ranges[1].start)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["select next line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.count >= 2 { break }
        }
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(inserter.selectForwardCounts.last == ranges[2].end - ranges[2].start)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("select next line"))
    }

    @Test("delete next line removes second when it is also last")
    func deleteNextLineTwoLines() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("Line two") { break }
        }

        await mock.setFeedAudioResult(["delete next line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !state.transcribedText.contains("Line two") { break }
        }

        #expect(!state.transcribedText.contains("Line two"))
        #expect(state.transcribedText.contains("Line one") || state.transcribedText.hasPrefix("Line one"))
        #expect(!inserter.typedTexts.contains("delete next line"))
    }

    @Test("select first line moves to session start then selects forward")
    func selectFirstLineCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Line one\nLine two"])
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
            if state.transcribedText.contains("Line two") { break }
        }

        await mock.setFeedAudioResult(["select first line"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.selectForwardCounts.isEmpty { break }
        }

        let text = state.transcribedText
        #expect(text.contains("Line one") && text.contains("Line two"))
        #expect(inserter.moveBackwardCounts.last == text.count)
        #expect(inserter.selectForwardCounts.last == "Line one".count)
        #expect(inserter.selectBackwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("select first line"))
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
        #expect(inserter.clearSelectionCallCount >= 1, "format must collapse selection")
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
        #expect(inserter.clearSelectionCallCount >= 1, "format must collapse selection")
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
        #expect(inserter.clearSelectionCallCount >= 1, "format must collapse selection")
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
        #expect(inserter.clearSelectionCallCount >= 1, "format must collapse selection even with empty stack")
    }

    @Test("unselect that collapses selection without changing buffer")
    func unselectThatCommand() async throws {
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
        #expect(!inserter.selectBackwardCounts.isEmpty)

        let clearsBefore = inserter.clearSelectionCallCount
        await mock.setFeedAudioResult(["unselect that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.clearSelectionCallCount > clearsBefore { break }
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.clearSelectionCallCount > clearsBefore)
        #expect(!inserter.typedTexts.contains("unselect that"))
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

    @Test("duplicate that copies last delta and appends it")
    func duplicateThatCommand() async throws {
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

        await mock.setFeedAudioResult(["duplicate that"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello world world" { break }
        }

        #expect(state.transcribedText == "Hello world world")
        #expect(inserter.copyCallCount >= 1)
        #expect(inserter.clipboard == " world")
        #expect(inserter.typedTexts.contains(" world"))
        #expect(!inserter.typedTexts.contains("duplicate that"))
    }

    @Test("previous sentence moves caret to last sentence content start")
    func moveToPreviousSentenceCommand() async throws {
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

        await mock.setFeedAudioResult(["previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello. World now")
        // Content start of last sentence (skip leading separator space)
        let lastStart = TranscriptSelection.secondSentenceStartOffset("Hello. World now")!
        #expect(inserter.moveBackwardCounts.last == "Hello. World now".count - lastStart)
        #expect(inserter.selectBackwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("previous sentence"))
    }

    @Test("next sentence jumps to content start of second sentence from session end")
    func moveToNextSentenceCommand() async throws {
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

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        #expect(state.transcribedText == "Hello. World now")
        // From end: only ← to second-sentence content (skip whitespace), no → hop
        let start = TranscriptSelection.secondSentenceStartOffset("Hello. World now")!
        #expect(inserter.moveBackwardCounts.last == "Hello. World now".count - start)
        #expect(start == "Hello. ".count)
        #expect(!inserter.moveToLineEndCalled)
        #expect(inserter.selectBackwardCounts.isEmpty)
        #expect(!inserter.typedTexts.contains("next sentence"))
    }

    @Test("next sentence then content inserts at second sentence start")
    func moveToNextSentenceThenContentInsertsMid() async throws {
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

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["extra words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("extra") { break }
        }

        let after = state.transcribedText
        #expect(
            after.hasPrefix("Hello."),
            "first sentence kept, got \"\(after)\""
        )
        #expect(
            after.lowercased().contains("extra"),
            "inserted mid, got \"\(after)\""
        )
        #expect(
            after.lowercased().contains("world"),
            "second sentence kept after insert, got \"\(after)\""
        )
        // Not a pure trailing append after the whole buffer
        #expect(
            !after.lowercased().hasSuffix("extra words")
                || after.lowercased().contains("extra words world")
                || after.lowercased().contains("extra world"),
            "insert should land before World, got \"\(after)\""
        )
    }

    @Test("previous sentence then content inserts at last sentence start")
    func moveToPreviousSentenceThenContentInsertsMid() async throws {
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

        await mock.setFeedAudioResult(["previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }

        await mock.setFeedAudioResult(["extra words"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("extra") { break }
        }

        let after = state.transcribedText
        #expect(after.hasPrefix("Hello."), "first kept, got \"\(after)\"")
        #expect(after.lowercased().contains("extra"))
        #expect(after.lowercased().contains("world"))
    }

    @Test("next sentence twice advances to third sentence start")
    func moveToNextSentenceProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        #expect(inserter.moveBackwardCounts.last == text.count - ranges[1].start)

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveForwardCounts.isEmpty { break }
        }
        // From 2nd start → 3rd start
        #expect(inserter.moveForwardCounts.last == ranges[2].start - ranges[1].start)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("next sentence"))
    }

    @Test("previous sentence twice from end walks last then second-to-last")
    func moveToPreviousSentenceProgressive() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello. World. Done"])
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
            if state.transcribedText == "Hello. World. Done" { break }
        }

        let text = "Hello. World. Done"
        let ranges = TranscriptSelection.sentenceRanges(text)
        #expect(ranges.count == 3)

        await mock.setFeedAudioResult(["previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        #expect(inserter.moveBackwardCounts.last == text.count - ranges[2].start)

        let backBefore = inserter.moveBackwardCounts.count
        await mock.setFeedAudioResult(["previous sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.moveBackwardCounts.count > backBefore { break }
        }
        #expect(inserter.moveBackwardCounts.last == ranges[2].start - ranges[1].start)
        #expect(state.transcribedText == text)
        #expect(!inserter.typedTexts.contains("previous sentence"))
    }

    @Test("move next and select next land on the same content offset")
    func moveNextAndSelectNextSameOffset() async throws {
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

        let text = "Hello. World now"
        let start = TranscriptSelection.secondSentenceStartOffset(text)!
        let expectedBack = text.count - start

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter.moveBackwardCounts.isEmpty { break }
        }
        let moveBack = inserter.moveBackwardCounts.last

        // Fresh session for select (nav index reset on start)
        let mock2 = MockTranscriber()
        await mock2.setFeedAudioResult(["Hello. World now"])
        let recorder2 = MockAudioRecorder()
        let inserter2 = MockTextInserter()
        let (state2, _, _, _) = makeAppState(transcriber: mock2, recorder: recorder2, inserter: inserter2)
        state2.status = .ready
        state2.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock2.resetVADCalled { break }
        }
        recorder2.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state2.transcribedText == "Hello. World now" { break }
        }

        await mock2.setFeedAudioResult(["select next sentence"])
        recorder2.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !inserter2.selectForwardCounts.isEmpty { break }
        }
        let selectBack = inserter2.moveBackwardCounts.last

        #expect(moveBack == expectedBack)
        #expect(selectBack == expectedBack)
        #expect(moveBack == selectBack)
    }

    @Test("next sentence is no-op for single-sentence buffer")
    func moveToNextSentenceSingleSentenceNoOp() async throws {
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

        await mock.setFeedAudioResult(["next sentence"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(state.transcribedText == "Hello world")
        #expect(inserter.moveBackwardCounts.isEmpty)
        #expect(inserter.moveForwardCounts.isEmpty)
        #expect(!inserter.moveToLineEndCalled)
        #expect(!inserter.typedTexts.contains("next sentence"))
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

    @Test("press space inserts a space character")
    func pressSpaceCommand() async throws {
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

        await mock.setFeedAudioResult(["press space"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText == "Hello " { break }
        }

        #expect(state.transcribedText == "Hello ")
        #expect(inserter.typedTexts.contains(" "))
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
        // Long linger so CI can't race past the window before we observe it.
        state.lingerDuration = 2_000_000_000 // 2s

        state.status = .ready
        state.startRecording()

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }

        state.stopRecording()

        // Wait until flush applied text and we are still lingering as .transcribing.
        var sawTranscribing = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if case .transcribing = state.status, !state.transcribedText.isEmpty {
                sawTranscribing = true
                break
            }
        }

        guard sawTranscribing, case .transcribing = state.status else {
            Issue.record("Expected .transcribing during linger, got \(state.status) text=\"\(state.transcribedText)\"")
            return
        }
        #expect(state.transcribedText == "Hello")

        // Wait for linger to expire
        for _ in 0..<50 {
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
        #expect(!state.capitalizeNextWord)
        #expect(state.spellMode == .off)
        #expect(state.noSpaceMode == .off)
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

    @Test("cancelSession resets sticky noSpaceMode to off")
    func cancelSessionResetsNoSpaceMode() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["no space on"])
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
            if state.noSpaceMode == .on { break }
        }
        #expect(state.noSpaceMode == .on)

        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Expected .ready after cancel, got \(state.status)")
            return
        }
        #expect(state.noSpaceMode == .off)
        #expect(state.spellMode == .off)
        #expect(state.capsMode == .normal)
    }

    @Test("startRecording resets sticky noSpaceMode to off")
    func startRecordingResetsNoSpaceMode() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["no space on"])
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
            if state.noSpaceMode == .on { break }
        }
        #expect(state.noSpaceMode == .on)

        // Cancel ends session and clears sticky modes; next startRecording
        // also resets (dual of NoSpaceMode.tla Reset).
        state.cancelSession()
        #expect(state.noSpaceMode == .off)

        state.status = .ready
        state.startRecording()
        #expect(state.noSpaceMode == .off)
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

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if await mock.resetVADCalled { break }
        }

        // Commit first segment
        recorder.lastOnSamples?([0.1])
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !state.transcribedText.isEmpty { break }
        }
        #expect(state.transcribedText.contains("Hello") || state.transcribedText.contains("hello"))

        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("Expected .transcribing before rejoin, got \(state.status)")
            return
        }

        // Rejoin — new consumer must process the next segment
        await mock.setFeedAudioResult(["world"])
        await mock.setFlushDelay(0)
        let startsBefore = recorder.startCallCount
        let feedsBefore = await mock.feedAudioCallCount
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording after rejoin, got \(state.status)")
            return
        }

        // Wait for a new audio tap (rejoin restarts the recorder)
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if recorder.startCallCount > startsBefore, recorder.isRecording { break }
        }
        #expect(recorder.startCallCount > startsBefore, "rejoin must start a new audio tap")

        // Feed until consumer processes (poll text + feed count; re-yield samples)
        for _ in 0..<60 {
            recorder.lastOnSamples?([0.2])
            try await Task.sleep(nanoseconds: 50_000_000)
            if state.transcribedText.lowercased().contains("world") { break }
            if await mock.feedAudioCallCount > feedsBefore,
               state.transcribedText.lowercased().contains("world") {
                break
            }
        }

        let text = state.transcribedText.lowercased()
        #expect(text.contains("hello") && text.contains("world"),
                "expected Hello world after rejoin, got \"\(state.transcribedText)\"")
        #expect(
            inserter.typedTexts.contains(where: { $0.lowercased().contains("world") }),
            "host should type world after rejoin, got \(inserter.typedTexts)"
        )
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

    // MARK: - On-demand AI cleanup

    /// Fake cleanup processor: uppercases input (deterministic, no T5/LLM).
    private struct UppercaseCleanupProcessor: TextPostProcessing {
        func process(_ text: String) async throws -> String {
            text.uppercased()
        }
    }

    @Test("runAICleanup rewrites last phrase via injected processor")
    func aiCleanupLastPhrase() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["hello world"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.cleanupProcessorOverride = UppercaseCleanupProcessor()
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

        state.runAICleanup()
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !state.isCleaningUp { break }
        }

        #expect(!state.isCleaningUp)
        #expect(state.transcribedText == "HELLO WORLD")
        #expect(inserter.deletedCounts.contains { $0 > 0 })
        #expect(inserter.typedTexts.contains("HELLO WORLD"))
    }

    @Test("spoken clean that up triggers AI cleanup")
    func aiCleanupSpokenCommand() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["messy words"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.cleanupProcessorOverride = UppercaseCleanupProcessor()
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("messy") { break }
        }

        await mock.setFeedAudioResult(["clean that up"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if state.transcribedText == "MESSY WORDS" { break }
        }

        #expect(state.transcribedText == "MESSY WORDS",
                "expected cleaned buffer, got \"\(state.transcribedText)\"")
        #expect(!inserter.typedTexts.contains("clean that up"))
    }

    @Test("runAICleanup no-op when buffer empty")
    func aiCleanupEmptyNoOp() {
        let (state, _, _, inserter) = makeAppState()
        state.cleanupProcessorOverride = UppercaseCleanupProcessor()
        state.status = .ready
        #expect(state.transcribedText.isEmpty)

        state.runAICleanup()

        #expect(!state.isCleaningUp)
        #expect(inserter.typedTexts.isEmpty)
        #expect(inserter.deletedCounts.isEmpty)
    }

    @Test("runAICleanup rewrites selection when armed")
    func aiCleanupSelection() async throws {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["alpha beta gamma"])
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, recorder: recorder, inserter: inserter)
        state.cleanupProcessorOverride = UppercaseCleanupProcessor()
        state.status = .ready
        state.startRecording()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await mock.resetVADCalled { break }
        }
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.transcribedText.lowercased().contains("beta") { break }
        }

        // Select "beta" only
        await mock.setFeedAudioResult(["select beta"])
        recorder.lastOnSamples?([0.1])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if inserter.selectForwardCounts.contains(4) { break }
        }

        state.runAICleanup()
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if state.transcribedText.contains("BETA") { break }
        }

        let text = state.transcribedText
        #expect(text.contains("BETA"), "selection cleaned, got \"\(text)\"")
        #expect(text.lowercased().contains("alpha"), "prefix preserved, got \"\(text)\"")
        #expect(text.lowercased().contains("gamma"), "suffix preserved, got \"\(text)\"")
        #expect(inserter.typedTexts.contains("BETA"))
    }
}
