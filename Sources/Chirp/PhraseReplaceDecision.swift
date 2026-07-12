// PhraseReplaceDecision.swift — Pure gates for phrase replace / delete.
// Dual of specs/ReplacePhrase.tla + specs/DeletePhrase.tla.
// Locates the last case-insensitive occurrence of `target` and splices.

import Foundation

enum PhraseReplaceDecision {
    /// Character-offset range of a match (end exclusive via start+length).
    struct Match: Equatable, Sendable {
        let start: Int
        let length: Int
    }

    /// Last case-insensitive occurrence of `target` in `buffer`. Nil if missing/empty.
    static func findLastRange(target: String, in buffer: String) -> Match? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !buffer.isEmpty else { return nil }
        guard let range = buffer.range(
            of: t,
            options: [.caseInsensitive, .backwards]
        ) else {
            return nil
        }
        let start = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        let length = buffer.distance(from: range.lowerBound, to: range.upperBound)
        guard length > 0 else { return nil }
        return Match(start: start, length: length)
    }

    /// Last case-insensitive occurrence of `target` whose start is **strictly before**
    /// `beforeStart`. Dual of SelectAgain.tla (walk earlier matches).
    /// Used by Dragon "select again" after a phrase select.
    static func findLastRange(
        target: String,
        in buffer: String,
        before beforeStart: Int
    ) -> Match? {
        guard beforeStart > 0 else { return nil }
        let end = min(beforeStart, buffer.count)
        guard end > 0 else { return nil }
        let prefix = String(buffer.prefix(end))
        return findLastRange(target: target, in: prefix)
    }

    /// First case-insensitive occurrence of `target` starting **at or after** `afterStart`.
    /// Dual of SelectAgain.tla SelectNext. Used by "select next occurrence".
    static func findFirstRange(
        target: String,
        in buffer: String,
        after afterStart: Int
    ) -> Match? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !buffer.isEmpty else { return nil }
        let start = min(max(afterStart, 0), buffer.count)
        guard start < buffer.count else { return nil }
        let from = buffer.index(buffer.startIndex, offsetBy: start)
        guard let range = buffer.range(
            of: t,
            options: .caseInsensitive,
            range: from..<buffer.endIndex
        ) else {
            return nil
        }
        let matchStart = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        let length = buffer.distance(from: range.lowerBound, to: range.upperBound)
        guard length > 0 else { return nil }
        return Match(start: matchStart, length: length)
    }

    /// Last match expanded to absorb one adjacent whitespace so delete does not
    /// leave double spaces ("hello world foo" → "hello foo").
    /// Prefers leading space; else trailing space.
    static func findLastDeletableRange(target: String, in buffer: String) -> Match? {
        guard let match = findLastRange(target: target, in: buffer) else { return nil }
        if match.start > 0 {
            let beforeIdx = buffer.index(buffer.startIndex, offsetBy: match.start - 1)
            if buffer[beforeIdx].isWhitespace {
                return Match(start: match.start - 1, length: match.length + 1)
            }
        }
        let end = match.start + match.length
        if end < buffer.count {
            let afterIdx = buffer.index(buffer.startIndex, offsetBy: end)
            if buffer[afterIdx].isWhitespace {
                return Match(start: match.start, length: match.length + 1)
            }
        }
        return match
    }

    /// Buffer after replacing last occurrence of `target` with `replacement`.
    /// Nil when no match (caller must leave text unchanged).
    static func bufferAfterReplace(
        buffer: String,
        target: String,
        replacement: String
    ) -> String? {
        guard let match = findLastRange(target: target, in: buffer) else { return nil }
        return SelectionCommitDecision.bufferAfterRangeReplace(
            buffer: buffer,
            start: match.start,
            length: match.length,
            replacement: replacement
        )
    }

    /// Buffer after deleting last occurrence of `target` (with space absorb).
    /// Nil when no match.
    static func bufferAfterDelete(buffer: String, target: String) -> String? {
        guard let match = findLastDeletableRange(target: target, in: buffer) else {
            return nil
        }
        return SelectionCommitDecision.bufferAfterRangeReplace(
            buffer: buffer,
            start: match.start,
            length: match.length,
            replacement: ""
        )
    }
}
