// PageScrollDecisionTests.swift — Dual of specs/PageScrollN.tla.

import Testing
@testable import Chirp

@Suite("PageScrollDecision")
struct PageScrollDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(PageScrollDecision.clampCount(0) == 1)
        #expect(PageScrollDecision.clampCount(-1) == 1)
        #expect(PageScrollDecision.clampCount(3) == 3)
        #expect(PageScrollDecision.clampCount(99) == PageScrollDecision.maxCount)
    }
}
