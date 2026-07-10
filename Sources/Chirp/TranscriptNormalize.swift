// TranscriptNormalize.swift — Lightweight compare key for segment dedup.

import Foundation

enum TranscriptNormalize {
    /// Lowercase, trim, strip trailing sentence punct — for echo detection.
    static func key(_ text: String) -> String {
        var n = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        return n.trimmingCharacters(in: .whitespaces)
    }
}
