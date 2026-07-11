// TabDecisionTests.swift — Dual of specs/TabN.tla.

import Testing
@testable import Chirp

@Suite("TabDecision")
struct TabDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(TabDecision.clampCount(0) == 1)
        #expect(TabDecision.clampCount(-2) == 1)
        #expect(TabDecision.clampCount(4) == 4)
        #expect(TabDecision.clampCount(100) == TabDecision.maxCount)
    }

    @Test("insertedLength equals clamped count")
    func length() {
        #expect(TabDecision.insertedLength(count: 3) == 3)
        #expect(TabDecision.insertedLength(count: 0) == 1)
        #expect(String(repeating: "\t", count: TabDecision.insertedLength(count: 2)).count == 2)
    }
}
