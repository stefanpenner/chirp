// SessionMachinePropertyTests.swift — Property bridge to specs/SessionMachine.tla
//
// TLC checks the abstract session machine. These tests assert the same
// transition guards and post-conditions against live AppState, so the
// Swift implementation cannot silently drift from the formal model.
//
// Spec actions: StartRecording, StopRecording, Rejoin, Cancel, FinishSession

import Testing
import Foundation
@testable import Chirp

@Suite("SessionMachine properties (TLA+ bridge)")
@MainActor
struct SessionMachinePropertyTests {

    private func makeReadyState() -> AppState {
        let state = AppState(
            audioRecorder: MockAudioRecorder(),
            transcriber: MockTranscriber(),
            textInserter: MockTextInserter(),
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000 // 1ms
        state.status = .ready
        return state
    }

    // MARK: - StartRecording (ready → recording)

    @Test("StartRecording enabled only from ready")
    func startRecordingGuard() {
        let state = makeReadyState()

        // Enabled from ready
        state.status = .ready
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("StartRecording from ready should yield recording")
            return
        }

        // Disabled from recording (no-op / not another new session clear)
        state.transcribedText = "kept"
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("StartRecording while recording should be ignored")
            return
        }
        #expect(state.transcribedText == "kept")
    }

    // MARK: - StopRecording (recording → transcribing)

    @Test("StopRecording enabled only from recording")
    func stopRecordingGuard() {
        let state = makeReadyState()
        state.status = .ready
        state.stopRecording()
        guard case .ready = state.status else {
            Issue.record("StopRecording from ready must be a no-op")
            return
        }

        state.status = .recording
        state.stopRecording()
        guard case .transcribing = state.status else {
            Issue.record("StopRecording from recording should yield transcribing")
            return
        }
    }

    // MARK: - Rejoin (transcribing → recording, text preserved)

    @Test("Rejoin preserves text and returns to recording")
    func rejoinPreservesText() {
        let state = makeReadyState()
        state.status = .transcribing
        state.transcribedText = "hello world"
        state.startRecording() // rejoin path

        guard case .recording = state.status else {
            Issue.record("Rejoin should yield recording")
            return
        }
        #expect(state.transcribedText == "hello world")
    }

    // MARK: - Cancel (recording|transcribing → ready, text cleared)

    @Test("Cancel from recording clears text and returns ready")
    func cancelFromRecording() {
        let state = makeReadyState()
        state.status = .recording
        state.transcribedText = "partial"
        state.speculativeText = "peek"
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Cancel should yield ready")
            return
        }
        #expect(state.transcribedText.isEmpty)
        #expect(state.speculativeText.isEmpty)
    }

    @Test("Cancel from transcribing clears text and returns ready")
    func cancelFromTranscribing() {
        let state = makeReadyState()
        state.status = .transcribing
        state.transcribedText = "almost done"
        state.cancelSession()

        guard case .ready = state.status else {
            Issue.record("Cancel should yield ready")
            return
        }
        #expect(state.transcribedText.isEmpty)
    }

    @Test("Cancel from ready is a no-op")
    func cancelFromReadyNoOp() {
        let state = makeReadyState()
        state.status = .ready
        state.transcribedText = "should stay"
        state.cancelSession()
        guard case .ready = state.status else {
            Issue.record("Cancel from ready must stay ready")
            return
        }
        #expect(state.transcribedText == "should stay")
    }

    // MARK: - FinishSession (transcribing → ready after flush)

    @Test("Natural finish returns to ready after flush")
    func finishSessionReturnsReady() async throws {
        let mock = MockTranscriber()
        await mock.setFlushResult("done")
        let state = AppState(
            audioRecorder: MockAudioRecorder(),
            transcriber: mock,
            textInserter: MockTextInserter(),
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000
        state.status = .ready
        state.startRecording()
        state.stopRecording()

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if case .ready = state.status { break }
        }
        guard case .ready = state.status else {
            Issue.record("FinishSession should eventually yield ready, got \(state.status)")
            return
        }
    }
}
