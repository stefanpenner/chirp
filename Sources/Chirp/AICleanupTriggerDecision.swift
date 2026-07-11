// AICleanupTriggerDecision.swift — Pure gates for on-demand AI cleanup triggers.
// Dual of specs/AICleanupTrigger.tla.

import Foundation

enum AICleanupTriggerDecision {
    /// Hold-to-talk is active and we should intercept the cleanup letter (e.g. C).
    /// Dual: AICleanupTrigger.tla HoldChordEnabled
    static func shouldHandleHoldChord(holdActive: Bool, suppressOnly: Bool) -> Bool {
        holdActive && !suppressOnly
    }

    /// Whether cleanup may start (has text, not already cleaning).
    /// Dual: AICleanupTrigger.tla CanStart
    static func canStart(hasText: Bool, isCleaningUp: Bool) -> Bool {
        hasText && !isCleaningUp
    }

    /// Menu / UI: human-readable chord label for current hold key.
    /// e.g. hold "fn" → "fn+C"; hold "Right ⌥" → "Right ⌥+C"
    static func holdChordLabel(holdKeyLabel: String) -> String {
        let base = holdKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "hold+C" }
        return "\(base)+C"
    }
}
