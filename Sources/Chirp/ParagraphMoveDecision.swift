// ParagraphMoveDecision.swift — Pure clamp for Dragon "move up/down N paragraphs".
// Dual of specs/MoveParagraphsN.tla + TranscriptSelection.offsetAfterParagraphMove.

import Foundation

enum ParagraphMoveDecision {
    /// Max paragraphs per utterance (Dragon caps ~20).
    static let maxCount = 20

    /// Clamp spoken count into 1...maxCount.
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), maxCount)
    }
}
