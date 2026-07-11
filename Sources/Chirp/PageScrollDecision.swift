// PageScrollDecision.swift — Pure clamp for "page up/down N times".
// Dual of specs/PageScrollN.tla (keyboard-only; buffer unchanged).

import Foundation

enum PageScrollDecision {
    /// Max page keys per utterance.
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }
}
