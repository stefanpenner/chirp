// SpaceDecision.swift — Pure clamp for "press space N times".
// Dual of specs/SpaceN.tla (session buffer grows by N spaces).

import Foundation

enum SpaceDecision {
    /// Max spaces per utterance.
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }

    /// Characters inserted for a space-N command.
    static func insertedLength(count: Int) -> Int {
        clampCount(count)
    }
}
