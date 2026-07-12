// CommandHotwords.swift — Dictation-command phrases for ASR contextual bias.
// SOTA offline STT (sherpa-onnx) boosts domain phrases via hotwords_file.
// Parakeet tokens use SentencePiece ▁word forms; bare "that" fails EncodeBase.
// We rewrite encodable phrases to vocab token strings (or drop them).

import Foundation

enum CommandHotwords {
    /// Token-level boost score (sherpa-onnx hotwords_score). Mild so free
    /// dictation is not pulled into commands on every utterance.
    static let score: Float = 1.5

    /// Max active paths when using modified_beam_search with hotwords.
    static let maxActivePaths: Int32 = 4

    /// SentencePiece word-boundary marker used in Parakeet tokens.txt.
    static let spWordMark: Character = "\u{2581}" // ▁

    /// High-value spoken commands to bias. Keep short multi-word phrases only
    /// (single common words like "undo" steal free dictation).
    static let seedPhrases: [String] = [
        // Undo / redo / replace
        "scratch that",
        "correct that",
        "fix that",
        "undo that",
        "redo that",
        "replace that",
        "delete that",
        // Select family
        "select that",
        "select again",
        "select next occurrence",
        "select previous occurrence",
        "select last word",
        "select last sentence",
        "select last paragraph",
        "select last line",
        "select all",
        "unselect that",
        // Nav / go
        "go to start",
        "go to end",
        "new line",
        "new paragraph",
        // Keys
        "press escape",
        "press backspace",
        "press back space", // ASR split of backspace
        "press enter",
        "press tab",
        "press space",
        "forward delete",
        // Caps / spell
        "cap that",
        "all caps that",
        "spell that",
        "spell mode",
        // Resume / insert
        "resume with",
        "insert before",
        "insert after",
        // Clipboard
        "copy that",
        "paste that",
        "cut that",
        "duplicate that",
        "bold that",
        "italic that",
        "underline that",
    ]

    /// Deduped, trimmed, lowercased phrases (non-empty, ≥2 tokens preferred).
    static var phrases: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in seedPhrases {
            let p = normalize(raw)
            guard !p.isEmpty else { continue }
            guard p.split(separator: " ").count >= 2 else { continue }
            guard seen.insert(p).inserted else { continue }
            out.append(p)
        }
        return out
    }

    /// Parse sherpa tokens.txt: first column is the token string.
    static func loadTokenSet(from path: String) -> Set<String>? {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var tokens = Set<String>()
        for line in data.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: { $0.isWhitespace || $0 == "\t" })
            guard let first = cols.first, !first.isEmpty else { continue }
            tokens.insert(String(first))
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// Map a spoken word to a tokens.txt entry (bare or ▁word).
    static func tokenForm(word: String, tokens: Set<String>) -> String? {
        let w = word.lowercased()
        if tokens.contains(w) { return w }
        let marked = String(spWordMark) + w
        if tokens.contains(marked) { return marked }
        return nil
    }

    /// Encode a multi-word phrase for hotwords_file, or nil if any word missing.
    /// Dual of sherpa EncodeBase: each space-separated piece must be a token ID.
    static func encodePhrase(_ phrase: String, tokens: Set<String>) -> String? {
        let words = normalize(phrase).split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(words.count)
        for w in words {
            guard let t = tokenForm(word: w, tokens: tokens) else { return nil }
            parts.append(t)
        }
        return parts.joined(separator: " ")
    }

    /// Phrases rewritten for tokens.txt (drops unencodable seeds).
    static func encodablePhrases(
        from list: [String] = phrases,
        tokens: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in list {
            guard let enc = encodePhrase(p, tokens: tokens) else { continue }
            guard seen.insert(enc).inserted else { continue }
            out.append(enc)
        }
        return out
    }

    /// Newline-separated body for `hotwords_file` (one phrase per line).
    static func fileBody(phrases list: [String] = phrases) -> String {
        list.joined(separator: "\n") + (list.isEmpty ? "" : "\n")
    }

    /// Slash-separated body for `SherpaOnnxCreateOfflineStreamWithHotwords`.
    static func streamBody(phrases list: [String] = phrases) -> String {
        list.joined(separator: "/")
    }

    /// Normalize a seed for the hotwords list.
    static func normalize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Write hotwords file. When `tokensPath` is set, only encodable phrases
    /// (SentencePiece-aware) are written — avoids EncodeBase skip spam.
    static func ensureFileOnDisk(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        tokensPath: String? = nil
    ) -> String? {
        let list: [String]
        if let tokensPath, let tokens = loadTokenSet(from: tokensPath) {
            list = encodablePhrases(tokens: tokens)
        } else {
            list = phrases
        }
        guard !list.isEmpty else { return nil }
        let dir: URL
        if let directory {
            dir = directory
        } else {
            guard let base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            dir = base.appendingPathComponent("Chirp", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("command-hotwords.txt")
            try fileBody(phrases: list).write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
