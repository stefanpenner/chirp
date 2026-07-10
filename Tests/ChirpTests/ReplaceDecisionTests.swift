// ReplaceDecisionTests.swift — Pure gates dual of specs/ReplaceThat.tla.

import Testing
@testable import Chirp

@Suite("ReplaceDecision")
struct ReplaceDecisionTests {

    @Test("canArm only with last phrase")
    func canArm() {
        #expect(ReplaceDecision.canArm(hasLastPhrase: true))
        #expect(!ReplaceDecision.canArm(hasLastPhrase: false))
    }

    @Test("shouldUndoBeforeCommit only when awaiting")
    func shouldUndo() {
        #expect(ReplaceDecision.shouldUndoBeforeCommit(awaitingReplace: true))
        #expect(!ReplaceDecision.shouldUndoBeforeCommit(awaitingReplace: false))
    }
}
