// ConfidenceGateTests.swift — Token log-prob accept/reject policy.

import Testing
@testable import Chirp

@Suite("ConfidenceGate")
struct ConfidenceGateTests {

    @Test("nil or empty probs always accept")
    func noScoresAccept() {
        #expect(ConfidenceGate.accept(tokenLogProbs: nil))
        #expect(ConfidenceGate.accept(tokenLogProbs: []))
    }

    @Test("healthy log probs accept")
    func healthyAccept() {
        #expect(ConfidenceGate.accept(tokenLogProbs: [-0.1, -0.2, -0.05]))
        #expect(ConfidenceGate.accept(tokenLogProbs: [-1.0, -1.5, -0.5]))
    }

    @Test("extreme low mean rejects")
    func extremeReject() {
        #expect(!ConfidenceGate.accept(tokenLogProbs: [-10, -12, -11]))
        #expect(!ConfidenceGate.accept(tokenLogProbs: [-5.1]))
    }

    @Test("mean at threshold accepts")
    func atThreshold() {
        #expect(ConfidenceGate.accept(tokenLogProbs: [ConfidenceGate.minMeanLogProb]))
    }

    @Test("meanLogProb averages")
    func mean() {
        #expect(ConfidenceGate.meanLogProb(tokenLogProbs: nil) == nil)
        let m = ConfidenceGate.meanLogProb(tokenLogProbs: [-1, -3])
        #expect(m == -2)
    }
}
