// ResumeWithDecision.swift — Pure "resume with X" truncate-after-match.
// Dual of specs/ResumeWith.tla. Dragon: keep text through last X, drop the rest.

import Foundation

enum ResumeWithDecision {
    /// Result of resume-with: truncated buffer, host delete count, caret at end.
    struct Result: Equatable, Sendable {
        let buffer: String
        /// Characters to deleteBackward on host when typed incrementally.
        let deletedCount: Int
        /// Caret offset after resume (= buffer.count; end/append mode).
        let caret: Int
    }

    /// Keep buffer through end of last case-insensitive `target`; drop suffix after.
    /// Nil when no match or target empty. No-op-ish when already trailing (deletedCount 0).
    static func truncateAfterLastMatch(target: String, buffer: String) -> Result? {
        guard let match = PhraseReplaceDecision.findLastRange(target: target, in: buffer) else {
            return nil
        }
        let end = match.start + match.length
        guard end >= 0, end <= buffer.count else { return nil }
        let kept = String(buffer.prefix(end))
        let deleted = buffer.count - end
        return Result(buffer: kept, deletedCount: deleted, caret: kept.count)
    }
}
