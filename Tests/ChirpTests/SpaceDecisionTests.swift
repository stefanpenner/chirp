// SpaceDecisionTests.swift — Dual of specs/SpaceN.tla.

import Testing
@testable import Chirp

@Suite("SpaceDecision")
struct SpaceDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(SpaceDecision.clampCount(0) == 1)
        #expect(SpaceDecision.clampCount(-3) == 1)
        #expect(SpaceDecision.clampCount(4) == 4)
        #expect(SpaceDecision.clampCount(50) == SpaceDecision.maxCount)
    }

    @Test("insertedLength equals clamped spaces")
    func length() {
        #expect(SpaceDecision.insertedLength(count: 3) == 3)
        #expect(String(repeating: " ", count: SpaceDecision.insertedLength(count: 2)) == "  ")
    }
}
