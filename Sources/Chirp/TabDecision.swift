// TabDecision.swift — Pure clamp for Dragon "Tab <n> times".
// Dual of specs/TabN.tla (session buffer grows by N tabs).

import Foundation

enum TabDecision {
    /// Max tabs per utterance (forms rarely need more).
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }

    /// Characters inserted for a tab-N command.
    static func insertedLength(count: Int) -> Int {
        clampCount(count)
    }
}
