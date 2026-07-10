// CancelDecisionTests.swift — Dual-test pure gate against CancelVoid.tla.

import Testing
@testable import Chirp

@Suite("CancelDecision (TLA+ dual)")
struct CancelDecisionTests {

    @Test("incremental with typed text returns full length")
    func incrementalWithText() {
        #expect(CancelDecision.appCharsToDelete(typedLength: 5, typesIncrementally: true) == 5)
        #expect(CancelDecision.appCharsToDelete(typedLength: 1, typesIncrementally: true) == 1)
        #expect(CancelDecision.appCharsToDelete(typedLength: 3, typesIncrementally: true) == 3)
    }

    @Test("incremental with empty text returns 0")
    func incrementalEmpty() {
        #expect(CancelDecision.appCharsToDelete(typedLength: 0, typesIncrementally: true) == 0)
    }

    @Test("batch mode never deletes even with typed length")
    func batchNeverDeletes() {
        #expect(CancelDecision.appCharsToDelete(typedLength: 5, typesIncrementally: false) == 0)
        #expect(CancelDecision.appCharsToDelete(typedLength: 1, typesIncrementally: false) == 0)
        #expect(CancelDecision.appCharsToDelete(typedLength: 0, typesIncrementally: false) == 0)
    }
}
