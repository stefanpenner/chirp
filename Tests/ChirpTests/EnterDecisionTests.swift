// EnterDecisionTests.swift — Dual of specs/EnterN.tla.

import Testing
@testable import Chirp

@Suite("EnterDecision")
struct EnterDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(EnterDecision.clampCount(0) == 1)
        #expect(EnterDecision.clampCount(-1) == 1)
        #expect(EnterDecision.clampCount(5) == 5)
        #expect(EnterDecision.clampCount(99) == EnterDecision.maxCount)
    }

    @Test("insertedLength equals clamped count of newlines")
    func length() {
        #expect(EnterDecision.insertedLength(count: 3) == 3)
        #expect(String(repeating: "\n", count: EnterDecision.insertedLength(count: 2)) == "\n\n")
    }
}
