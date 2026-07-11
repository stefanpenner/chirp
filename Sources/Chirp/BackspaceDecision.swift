// BackspaceDecision.swift — Pure host key-repeat clamp (Backspace / Forward Delete).
// Dual of specs/BackspaceN.tla and specs/ForwardDeleteN.tla (host-only peel).

import Foundation

enum BackspaceDecision {
    /// Max host key presses per utterance (safety bound).
    static let maxCount = 100

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }

    /// How many characters a host key of `count` removes when
    /// `hostDeletable` chars sit on that side of the caret (model only).
    static func peel(hostDeletable: Int, count: Int) -> Int {
        let n = clampCount(count)
        return min(max(hostDeletable, 0), n)
    }
}
