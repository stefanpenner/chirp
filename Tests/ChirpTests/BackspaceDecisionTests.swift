// BackspaceDecisionTests.swift — Dual of specs/BackspaceN.tla.

import Testing
@testable import Chirp

@Suite("BackspaceDecision")
struct BackspaceDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(BackspaceDecision.clampCount(0) == 1)
        #expect(BackspaceDecision.clampCount(-2) == 1)
        #expect(BackspaceDecision.clampCount(5) == 5)
        #expect(BackspaceDecision.clampCount(500) == BackspaceDecision.maxCount)
    }

    @Test("peel never exceeds host deletable")
    func peel() {
        #expect(BackspaceDecision.peel(hostDeletable: 10, count: 3) == 3)
        #expect(BackspaceDecision.peel(hostDeletable: 2, count: 5) == 2)
        #expect(BackspaceDecision.peel(hostDeletable: 0, count: 3) == 0)
        #expect(BackspaceDecision.peel(hostDeletable: 4, count: 0) == 1) // clamped then min
    }
}
