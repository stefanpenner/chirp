// SessionDecisionTests.swift — Dual-test pure gate against SessionMachine.tla Can* actions.

import Testing
@testable import Chirp

@Suite("SessionDecision (TLA+ dual)")
struct SessionDecisionTests {

    @Test("StartRecording only from ready")
    func startRecording() {
        #expect(SessionDecision.canStartRecording(.ready))
        #expect(!SessionDecision.canStartRecording(.recording))
        #expect(!SessionDecision.canStartRecording(.transcribing))
    }

    @Test("StopRecording only from recording")
    func stopRecording() {
        #expect(SessionDecision.canStopRecording(.recording))
        #expect(!SessionDecision.canStopRecording(.ready))
        #expect(!SessionDecision.canStopRecording(.transcribing))
    }

    @Test("Rejoin only from transcribing")
    func rejoin() {
        #expect(SessionDecision.canRejoin(.transcribing))
        #expect(!SessionDecision.canRejoin(.ready))
        #expect(!SessionDecision.canRejoin(.recording))
    }

    @Test("Cancel from recording or transcribing")
    func cancel() {
        #expect(SessionDecision.canCancel(.recording))
        #expect(SessionDecision.canCancel(.transcribing))
        #expect(!SessionDecision.canCancel(.ready))
    }

    @Test("Finish only from transcribing")
    func finish() {
        #expect(SessionDecision.canFinish(.transcribing))
        #expect(!SessionDecision.canFinish(.ready))
        #expect(!SessionDecision.canFinish(.recording))
    }

    @Test("phase mapping from AppState.Status")
    func phaseMapping() {
        #expect(SessionDecision.phase(from: .ready) == .ready)
        #expect(SessionDecision.phase(from: .recording) == .recording)
        #expect(SessionDecision.phase(from: .transcribing) == .transcribing)
        #expect(SessionDecision.phase(from: .loadingModel) == nil)
        #expect(SessionDecision.phase(from: .needsModel) == nil)
    }
}
