// CommandNearMiss.swift — Full-utterance ASR repair before DictationCommand.parse.
// Short command hyps often glue or swap phonemes (SOTA short-utterance gap).
// Only rewrites the **whole** candidate (after lower/punct normalize) so free
// dictation mid-sentence is never stolen. Pure dual; wired from parse().

import Foundation

enum CommandNearMiss {
    /// Map full-utterance ASR dumps → canonical command text.
    /// Keys must already be lowercased, punct-stripped, single-spaced.
    static let fullUtteranceRepairs: [String: String] = [
        // cap that (TTS→Parakeet often collapses to one token)
        "capta": "cap that",
        "cap ta": "cap that",
        "capt that": "cap that",
        "capthat": "cap that",
        "kab that": "cap that",
        "cap the": "cap that", // lone utterance only via full-utterance gate
        // paste that
        "taste that": "paste that",
        "taste it": "paste that",
        "paced that": "paste that",
        // backspace
        "press back space": "press backspace",
        "hit back space": "press backspace",
        "back space": "press backspace",
        // select again
        "select a gain": "select again",
        "select againn": "select again",
        // select that
        "select dat": "select that",
        "selected that": "select that",
        "selected it": "select that",
        // scratch that
        "scratch hat": "scratch that",
        "scrap hat": "scratch that",
        "scrap that": "scratch that",
        "undo hat": "scratch that",
        "scratched that": "scratch that",
        "scratched it": "scratch that",
    ]

    /// Normalize hyp the same way as DictationCommand candidate prep (subset).
    static func normalizeKey(_ text: String) -> String {
        var n = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// If the entire utterance is a known ASR dump, return repaired command text.
    /// Otherwise return input unchanged (after only whitespace collapse when repaired).
    static func repair(_ text: String) -> String {
        let key = normalizeKey(text)
        guard !key.isEmpty else { return text }
        if let fixed = fullUtteranceRepairs[key] {
            return fixed
        }
        // Collapse glued multi-word commands: "selectthat" → "select that"
        if let expanded = expandGlued(key) {
            return expanded
        }
        return text
    }

    /// Known command surfaces without spaces (for glue repair).
    /// Longest-first match.
    static let gluedCommands: [(glued: String, spaced: String)] = {
        let spaced = [
            "scratch that",
            "select that",
            "select again",
            "select last word",
            "press escape",
            "press backspace",
            "press enter",
            "press tab",
            "press space",
            "forward delete",
            "cap that",
            "all caps that",
            "spell that",
            "copy that",
            "paste that",
            "cut that",
            "duplicate that",
            "redo that",
            "replace that",
            "undo that",
            "correct that",
            "unselect that",
        ]
        return spaced
            .map { ($0.replacingOccurrences(of: " ", with: ""), $0) }
            .sorted { $0.0.count > $1.0.count }
    }()

    /// If key is a known command with spaces removed, restore spaces.
    static func expandGlued(_ key: String) -> String? {
        for pair in gluedCommands {
            if key == pair.glued { return pair.spaced }
        }
        return nil
    }
}
