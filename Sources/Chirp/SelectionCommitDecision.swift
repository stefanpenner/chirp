// SelectionCommitDecision.swift — Pure gates for trailing selection → re-dictate.
// Dual of specs/SelectionCommit.tla.
// When the user selects a trailing buffer suffix then speaks content, the host
// app type-overwrites the selection; the session buffer must peel the same
// suffix so scratch / select / replace stay coherent.

import Foundation

enum SelectionCommitDecision {
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

    /// Session text after selection replace: peel suffix then concat replacement
    /// (no SegmentJoiner space — host type-overwrites the selection in place).
    static func bufferAfterReplace(buffer: String, selection: String, replacement: String) -> String {
        let base = baseAfterPeel(buffer: buffer, selection: selection)
        return base + replacement
    }
}
