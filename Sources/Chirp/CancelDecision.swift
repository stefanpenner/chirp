// CancelDecision.swift — Pure decision gate for ESC cancel voiding.
// Dual-tested against specs/CancelVoid.tla. AppState.cancelSession calls
// appCharsToDelete before clearing transcribedText so already-typed
// incremental text is removed from the focused app (Dragon-style void).

import Foundation

/// Pure functions for cancel void policy (no I/O, no side effects).
enum CancelDecision {
    /// How many characters to delete from the focused app on cancel.
    /// Incremental sessions type mid-recording → void that text.
    /// Batch mode types only at flush → nothing to delete mid-session.
    static func appCharsToDelete(typedLength: Int, typesIncrementally: Bool) -> Int {
        (typesIncrementally && typedLength > 0) ? typedLength : 0
    }
}
