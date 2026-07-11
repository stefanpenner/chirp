// SelectionCommitDecision.swift — Pure gates for selection → re-dictate.
// Dual of specs/SelectionCommit.tla.
// When the user selects buffer text then speaks content, the host app
// type-overwrites the selection; the session buffer must splice the same
// range so scratch / select / replace stay coherent.

import Foundation

enum SelectionCommitDecision {
    // MARK: - Range-based (any in-buffer selection)

    /// True when start/length form a non-empty in-bounds window of `bufferCount`.
    static func isInRange(start: Int, length: Int, bufferCount: Int) -> Bool {
        length > 0 && start >= 0 && start + length <= bufferCount
    }

    /// True when the window is a trailing suffix of the buffer.
    static func isTrailing(start: Int, length: Int, bufferCount: Int) -> Bool {
        isInRange(start: start, length: length, bufferCount: bufferCount)
            && start + length == bufferCount
    }

    /// Splice `replacement` over `[start, start+length)`. Nil when OOB.
    /// No SegmentJoiner space — host type-overwrites the selection in place.
    static func bufferAfterRangeReplace(
        buffer: String,
        start: Int,
        length: Int,
        replacement: String
    ) -> String? {
        guard isInRange(start: start, length: length, bufferCount: buffer.count) else {
            return nil
        }
        let s = buffer.index(buffer.startIndex, offsetBy: start)
        let e = buffer.index(s, offsetBy: length)
        return String(buffer[..<s]) + replacement + String(buffer[e...])
    }

    // MARK: - Trailing suffix helpers (compat / call sites)

    /// True when `selection` is a non-empty trailing suffix of `buffer`.
    static func shouldReplaceSuffix(selection: String?, buffer: String) -> Bool {
        guard let selection, !selection.isEmpty else { return false }
        return buffer.hasSuffix(selection)
    }

    /// Buffer with trailing `selection` removed. Returns `buffer` unchanged
    /// when selection is not a suffix (caller should not peel).
    static func baseAfterPeel(buffer: String, selection: String) -> String {
        guard buffer.hasSuffix(selection) else { return buffer }
        return String(buffer.dropLast(selection.count))
    }

    /// Session text after trailing selection replace: peel suffix then concat.
    static func bufferAfterReplace(buffer: String, selection: String, replacement: String) -> String {
        let base = baseAfterPeel(buffer: buffer, selection: selection)
        return base + replacement
    }
}
