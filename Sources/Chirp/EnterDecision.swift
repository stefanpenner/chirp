// EnterDecision.swift — Pure clamp for Dragon "press enter N times".
// Dual of specs/EnterN.tla (session buffer grows by N newlines).

import Foundation

enum EnterDecision {
    /// Max returns per utterance.
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }

    /// Characters inserted for an enter-N command.
    static func insertedLength(count: Int) -> Int {
        clampCount(count)
    }
}
