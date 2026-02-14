import Testing
import Foundation
@testable import Chirp

@Suite("AppState")
@MainActor
struct AppStateTests {

    private func makeAppState(
        transcriber: MockTranscriber = MockTranscriber(),
        recorder: MockAudioRecorder = MockAudioRecorder(),
        inserter: MockTextInserter = MockTextInserter()
    ) -> (AppState, MockTranscriber, MockAudioRecorder, MockTextInserter) {
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter
        )
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

        // Give the Task a moment to run
        try await Task.sleep(nanoseconds: 50_000_000)
        let called = await mock.resetVADCalled
        #expect(called)
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
        let inserter = MockTextInserter()
        let (state, _, _, _) = makeAppState(transcriber: mock, inserter: inserter)

        state.status = .recording
        state.stopRecording()

        // Wait for the async flush Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        let flushed = await mock.flushCalled
        #expect(flushed)
        #expect(inserter.typedTexts.contains("hello world"))
    }

    @Test("switchVariant no-ops when not ready")
    func switchVariantNoOp() {
        let (state, _, _, _) = makeAppState()
        state.status = .loadingModel
        let original = state.selectedVariant
        let other: ModelVariant = original == .tdt ? .ctc : .tdt
        state.switchVariant(other)
        #expect(state.selectedVariant == original)
    }

    @Test("switchVariant changes selectedVariant when ready")
    func switchVariantChanges() {
        let (state, _, _, _) = makeAppState()
        state.status = .ready
        let other: ModelVariant = state.selectedVariant == .tdt ? .ctc : .tdt
        state.switchVariant(other)
        #expect(state.selectedVariant == other)
    }
}

// Helper extension for setting mock values
extension MockTranscriber {
    func setFlushResult(_ value: String) {
        flushResult = value
    }
}
