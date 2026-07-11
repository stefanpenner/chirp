// LineMoveDecision.swift — Pure clamp for Dragon "move up/down N lines".
// Dual of specs/MoveLinesN.tla (buffer-preserving multi-line host move).

import Foundation

enum LineMoveDecision {
    /// Max lines per utterance (Dragon typically caps around 20).
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }
}
