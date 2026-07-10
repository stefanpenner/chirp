// ReplaceDecision.swift — Pure gates for multi-step "replace that".
// Dual-tested against specs/ReplaceThat.tla.

import Foundation

enum ReplaceDecision {
    /// Arm only when there is a last phrase to replace.
    static func canArm(hasLastPhrase: Bool) -> Bool {
        hasLastPhrase
    }

    /// Next content should first undo the last phrase.
    static func shouldUndoBeforeCommit(awaitingReplace: Bool) -> Bool {
        awaitingReplace
    }
}
