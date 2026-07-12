// CommandHotwords.swift — Dictation-command phrases for ASR contextual bias.
// SOTA offline STT (sherpa-onnx / Riva / Google adaptation) boosts domain phrases.
// Pure list + file/stream format — Transcriber wires them into the decoder.

import Foundation

enum CommandHotwords {
    /// Token-level boost score (sherpa-onnx hotwords_score). Mild so free
    /// dictation is not pulled into commands on every utterance.
    static let score: Float = 1.5

    /// Max active paths when using modified_beam_search with hotwords.
    static let maxActivePaths: Int32 = 4

    /// High-value spoken commands to bias. Keep short multi-word phrases only
    /// (single common words like "undo" steal free dictation).
    /// Order does not matter; dedupe is applied in `phrases`.
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
    ]

    /// Deduped, trimmed, lowercased phrases (non-empty, ≥2 tokens preferred).
    /// Single-token seeds are dropped (too steal-y for free dictation).
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

    /// Write hotwords file under Application Support; returns path or nil.
    static func ensureFileOnDisk(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) -> String? {
        let list = phrases
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
