// StreamingPartialDecisionTests.swift — Dual of specs/StreamingPartial.tla.

import Testing
@testable import Chirp

@Suite("StreamingPartialDecision (TLA+ dual)")
struct StreamingPartialDecisionTests {

    @Test("product default is peek-only")
    func productDefault() {
        #expect(StreamingPartialDecision.productDefault == .peekOnly)
    }

    @Test("partial UI only in recording or transcribing")
    func showPartial() {
        #expect(StreamingPartialDecision.canShowPartial(phase: .recording))
        #expect(StreamingPartialDecision.canShowPartial(phase: .transcribing))
        #expect(!StreamingPartialDecision.canShowPartial(phase: .ready))
    }

    @Test("EOU only accepted in streaming mode")
    func eouMode() {
        #expect(!StreamingPartialDecision.acceptsEOU(mode: .peekOnly))
        #expect(StreamingPartialDecision.acceptsEOU(mode: .streamingEOU))
    }

    @Test("peek-only never auto-commits on EOU")
    func peekOnlyNoEOUCommit() {
        #expect(!StreamingPartialDecision.shouldAutoCommitOnEOU(
            mode: .peekOnly,
            phase: .recording,
            eouFired: true,
            partialNonEmpty: true
        ))
    }

    @Test("streaming EOU auto-commit requires all gates")
    func streamingEOUCommit() {
        #expect(StreamingPartialDecision.shouldAutoCommitOnEOU(
            mode: .streamingEOU,
            phase: .recording,
            eouFired: true,
            partialNonEmpty: true
        ))
        #expect(!StreamingPartialDecision.shouldAutoCommitOnEOU(
            mode: .streamingEOU,
            phase: .recording,
            eouFired: true,
            partialNonEmpty: false
        ))
        #expect(!StreamingPartialDecision.shouldAutoCommitOnEOU(
            mode: .streamingEOU,
            phase: .transcribing,
            eouFired: true,
            partialNonEmpty: true
        ))
        #expect(!StreamingPartialDecision.shouldAutoCommitOnEOU(
            mode: .streamingEOU,
            phase: .recording,
            eouFired: false,
            partialNonEmpty: true
        ))
    }

    @Test("peek partial only while peekOnly + recording + speech")
    func peekPartialGates() {
        #expect(StreamingPartialDecision.canPeekPartial(
            mode: .peekOnly, phase: .recording, speechActive: true
        ))
        #expect(!StreamingPartialDecision.canPeekPartial(
            mode: .peekOnly, phase: .recording, speechActive: false
        ))
        #expect(!StreamingPartialDecision.canPeekPartial(
            mode: .streamingEOU, phase: .recording, speechActive: true
        ))
        #expect(!StreamingPartialDecision.canPeekPartial(
            mode: .peekOnly, phase: .ready, speechActive: true
        ))
    }

    @Test("stream partial only while streamingEOU + recording + speech")
    func streamPartialGates() {
        #expect(StreamingPartialDecision.canStreamPartial(
            mode: .streamingEOU, phase: .recording, speechActive: true
        ))
        #expect(!StreamingPartialDecision.canStreamPartial(
            mode: .peekOnly, phase: .recording, speechActive: true
        ))
    }

    @Test("phase mapping from AppState.Status")
    func phaseMap() {
        #expect(StreamingPartialDecision.phase(from: .ready) == .ready)
        #expect(StreamingPartialDecision.phase(from: .recording) == .recording)
        #expect(StreamingPartialDecision.phase(from: .transcribing) == .transcribing)
        #expect(StreamingPartialDecision.phase(from: .loadingModel) == nil)
    }
}
