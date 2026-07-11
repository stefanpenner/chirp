// PhraseReplaceDecision.swift — Pure gates for single-utterance "replace X with Y".
// Dual of specs/ReplacePhrase.tla.
// Locates the last case-insensitive occurrence of `target` and splices `replacement`.

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
}
