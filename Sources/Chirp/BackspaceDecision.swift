// BackspaceDecision.swift — Pure Dragon "Backspace <n>" clamp.
// Dual of specs/BackspaceN.tla (host-only peel; buffer unchanged).

import Foundation

enum BackspaceDecision {
    /// Max host Backspace presses per utterance (safety bound).
    static let maxCount = 100

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }

    /// How many characters a host backspace of `count` removes when
    /// `hostDeletable` chars sit left of the caret (model only; UI uses raw N).
    static func peel(hostDeletable: Int, count: Int) -> Int {
        let n = clampCount(count)
        return min(max(hostDeletable, 0), n)
    }
}
