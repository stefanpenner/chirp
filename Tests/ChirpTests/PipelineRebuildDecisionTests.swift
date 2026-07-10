// PipelineRebuildDecisionTests.swift — Dual-test against PipelineRebuild.tla.

import Testing
@testable import Chirp

@Suite("PipelineRebuildDecision")
struct PipelineRebuildDecisionTests {

    @Test("defer while recording or transcribing")
    func deferActive() {
        #expect(PipelineRebuildDecision.shouldDefer(phase: .recording))
        #expect(PipelineRebuildDecision.shouldDefer(phase: .transcribing))
        #expect(!PipelineRebuildDecision.shouldDefer(phase: .ready))
        #expect(!PipelineRebuildDecision.shouldDefer(phase: nil))
    }

    @Test("apply only when idle with pending flag")
    func canApply() {
        #expect(PipelineRebuildDecision.canApply(phase: .ready, pending: true))
        #expect(!PipelineRebuildDecision.canApply(phase: .ready, pending: false))
        #expect(!PipelineRebuildDecision.canApply(phase: .recording, pending: true))
        #expect(!PipelineRebuildDecision.canApply(phase: .transcribing, pending: true))
        #expect(PipelineRebuildDecision.canApply(phase: nil, pending: true))
    }
}
