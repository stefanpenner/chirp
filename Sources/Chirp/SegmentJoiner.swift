// SegmentJoiner.swift — Pure rules for joining VAD/ASR segments into one transcript.
// When VAD splits utterances on silence, the second often starts capitalized but
// the first may lack a terminal period ("Hello world" + "Create a note.").
// Insert ". " only when that pattern is clear; never invent punctuation mid-clause.

import Foundation

enum SegmentJoiner {
    /// Join `next` onto `existing`. Returns the full text and the delta to type.
    static func append(existing: String, next: String) -> (full: String, delta: String) {
        let piece = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else {
            return (existing, "")
        }
        if existing.isEmpty {
            return (piece, piece)
        }

        let separator = separator(between: existing, and: piece)
        let delta = separator + piece
        return (existing + delta, delta)
    }

    /// Separator between two non-empty segment strings.
    static func separator(between existing: String, and next: String) -> String {
        guard let last = existing.last else { return "" }

        // Already has terminal punctuation → single space
        if ".!?".contains(last) {
            return " "
        }
        // Trailing whitespace already present
        if last.isWhitespace {
            return needsSentenceBreak(existing: existing.trimmingCharacters(in: .whitespaces), next: next)
                ? ". "
                : ""
        }

        if needsSentenceBreak(existing: existing, next: next) {
            return ". "
        }
        return " "
    }

    /// True when `next` looks like a new sentence and `existing` does not end with punct.
    private static func needsSentenceBreak(existing: String, next: String) -> Bool {
        guard let first = next.first else { return false }
        // New segment starts with uppercase letter → likely a new sentence after silence
        guard first.isLetter, first.isUppercase else { return false }
        // Existing should end with a letter/digit (not already punct)
        guard let last = existing.last, last.isLetter || last.isNumber else { return false }
        return true
    }
}
