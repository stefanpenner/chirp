// AICleanupTriggerDecisionTests.swift — Dual of specs/AICleanupTrigger.tla.

import Testing
@testable import Chirp

@Suite("AICleanupTriggerDecision")
struct AICleanupTriggerDecisionTests {

    @Test("hold chord only when hold active and not suppress-only")
    func holdChordGate() {
        #expect(AICleanupTriggerDecision.shouldHandleHoldChord(
            holdActive: true, suppressOnly: false
        ))
        #expect(!AICleanupTriggerDecision.shouldHandleHoldChord(
            holdActive: false, suppressOnly: false
        ))
        #expect(!AICleanupTriggerDecision.shouldHandleHoldChord(
            holdActive: true, suppressOnly: true
        ))
    }

    @Test("canStart requires text and not already cleaning")
    func canStart() {
        #expect(AICleanupTriggerDecision.canStart(hasText: true, isCleaningUp: false))
        #expect(!AICleanupTriggerDecision.canStart(hasText: false, isCleaningUp: false))
        #expect(!AICleanupTriggerDecision.canStart(hasText: true, isCleaningUp: true))
        #expect(!AICleanupTriggerDecision.canStart(hasText: false, isCleaningUp: true))
    }

    @Test("holdChordLabel joins hold key with +C")
    func chordLabel() {
        #expect(AICleanupTriggerDecision.holdChordLabel(holdKeyLabel: "fn") == "fn+C")
        #expect(AICleanupTriggerDecision.holdChordLabel(holdKeyLabel: "Right ⌥") == "Right ⌥+C")
        #expect(AICleanupTriggerDecision.holdChordLabel(holdKeyLabel: "") == "hold+C")
    }
}
