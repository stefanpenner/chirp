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

    @Test("mean at length-specific threshold accepts")
    func atThreshold() {
        // Short (1 token): threshold -3.0
        #expect(ConfidenceGate.accept(tokenLogProbs: [-3.0]))
        // Long (9+): base minMeanLogProb -5.0
        let longAtBase = Array(repeating: ConfidenceGate.minMeanLogProb, count: 9)
        #expect(ConfidenceGate.accept(tokenLogProbs: longAtBase))
    }

    @Test("short hyp mean -4.0 rejects under strict short threshold")
    func shortStrictReject() {
        // Short threshold -3.0; mean -4.0 would pass medium/long but fails short
        #expect(!ConfidenceGate.accept(tokenLogProbs: [-4.0]))
        #expect(!ConfidenceGate.accept(tokenLogProbs: [-4.0, -4.0]))
    }

    @Test("long hyp mean -4.5 accepts under lenient long threshold")
    func longLenientAccept() {
        // Long threshold -5.0; mean -4.5 is above
        let long = Array(repeating: Float(-4.5), count: 9)
        #expect(ConfidenceGate.accept(tokenLogProbs: long))
    }

    @Test("minMeanLogProb(forTokenCount:) bands")
    func lengthBands() {
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 1) == -3.0)
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 2) == -3.0)
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 3) == -4.0)
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 8) == -4.0)
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 9) == ConfidenceGate.minMeanLogProb)
        #expect(ConfidenceGate.minMeanLogProb(forTokenCount: 20) == ConfidenceGate.minMeanLogProb)
    }

    @Test("meanLogProb averages")
    func mean() {
        #expect(ConfidenceGate.meanLogProb(tokenLogProbs: nil) == nil)
        let m = ConfidenceGate.meanLogProb(tokenLogProbs: [-1, -3])
        #expect(m == -2)
    }
}
