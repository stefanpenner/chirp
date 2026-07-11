// SessionCaretDecision.swift — Pure mid-buffer insert at session caret.
// Dual of specs/GoToPhrase.tla Commit-at-caret (and SessionCaret if split).
// After go-to / go-after, host caret is mid-text; session buffer must insert
// at the same offset so scratch/select/replace stay coherent.

import Foundation

enum SessionCaretDecision {
    /// True when caret is a mid-buffer insert point (not end / not OOB).
    static func isMidBuffer(caret: Int?, bufferCount: Int) -> Bool {
        guard let caret else { return false }
        return caret >= 0 && caret < bufferCount
    }

    /// Host caret position before a relative move to `target`.
    /// Dual of specs/HostCaret.tla HostFrom.
    ///
    /// Priority:
    /// 1. Unit nav anchor (sentence/paragraph/line start, or end after collapse)
    /// 2. sessionCaret (after go-to / word·char move)
    /// 3. End of buffer (default)
    static func hostFrom(
        bufferCount: Int,
        sessionCaret: Int?,
        unitAnchor: Int?
    ) -> Int {
        if let unit = unitAnchor {
            return max(0, min(unit, bufferCount))
        }
        if let caret = sessionCaret, caret >= 0, caret <= bufferCount {
            return caret
        }
        return max(0, bufferCount)
    }

    /// Relative host keystroke count: positive = forward, negative = backward.
    static func moveDelta(from: Int, to: Int) -> Int {
        to - from
    }

    /// Insert `piece` at `caret` using SegmentJoiner rules vs the left prefix.
    /// Returns full buffer, new caret (after inserted text + any join space
    /// before the right remainder), and the host type-delta.
    /// Nil when caret OOB. Empty piece → no-op.
    static func bufferAfterInsert(
        buffer: String,
        caret: Int,
        piece: String,
        preserveLeadingCase: Bool = false,
        emptySeparator: Bool = false
    ) -> (text: String, caret: Int, delta: String)? {
        guard caret >= 0, caret <= buffer.count else { return nil }
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (buffer, caret, "")
        }
        let left = String(buffer.prefix(caret))
        let right = String(buffer.dropFirst(caret))
        let joined = SegmentJoiner.append(
            existing: left,
            next: trimmed,
            preserveLeadingCase: preserveLeadingCase,
            emptySeparator: emptySeparator
        )
        // Space before right remainder if both sides are non-space-adjacent.
        let needSpaceBeforeRight =
            !right.isEmpty
            && !(joined.full.last?.isWhitespace ?? true)
            && !(right.first?.isWhitespace ?? true)
            && !emptySeparator
        var typeDelta = joined.delta
        if needSpaceBeforeRight {
            typeDelta += " "
        }
        // Collapse if joined ends with whitespace and right starts with whitespace.
        let rightPart: String
        if joined.full.last?.isWhitespace == true, right.first?.isWhitespace == true {
            rightPart = String(right.dropFirst())
        } else if needSpaceBeforeRight {
            rightPart = " " + right
        } else {
            rightPart = right
        }
        let full = joined.full + rightPart
        // Caret after inserted content (and after the space we typed before right).
        let newCaret = joined.full.count + (needSpaceBeforeRight ? 1 : 0)
        return (full, newCaret, typeDelta)
    }
}
