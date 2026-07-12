// CommandNearMiss.swift — Full-utterance ASR repair before DictationCommand.parse.
// Short command hyps often glue or swap phonemes (SOTA short-utterance gap).
// Only rewrites the **whole** candidate (after lower/punct normalize) so free
// dictation mid-sentence is never stolen. Pure dual; wired from parse().
//
// Repair order:
//   1) exact dump map  2) glued expand  3) bounded Levenshtein (unique, starter-gated)
// Fuzzy decision dual: specs/FuzzyCommand.tla (unique min dist → match).

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
        // Multi-voice soak: "cap that" → Hap/Have/Caplat dumps
        "hap that": "cap that",
        "hab that": "cap that",
        "hat that": "cap that",
        "crap that": "cap that",
        "have that": "cap that",
        "had that": "cap that",
        "caplat": "cap that",
        "captage": "cap that",
        "cab zot": "cap that",
        // paste that
        "taste that": "paste that",
        "taste it": "paste that",
        "paced that": "paste that",
        "face that": "paste that",
        "faced that": "paste that",
        "hey dad": "paste that",
        "hay dad": "paste that",
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
        // bold that (TTS→Parakeet: Ball Dad / Bulldog / Build that)
        "ball dad": "bold that",
        "ball that": "bold that",
        "bold dad": "bold that",
        "bald that": "bold that",
        "bulldog": "bold that",
        "build that": "bold that",
        "built that": "bold that",
        "ball t": "bold that",
        "bold touch": "bold that",
        // undo that (ASR near-misses; "undo hat" already → scratch that above)
        "until that": "undo that",
        "under that": "undo that",
        // redo that
        "we do that": "redo that",
        "reed that": "redo that",
        // scratch that
        "scratch badge": "scratch that",
        "scratch batch": "scratch that",
        // press escape / enter (ASR inserts "Chris" on some accents)
        "chris escape": "press escape",
        "press chris escape": "press escape",
        "chris enter": "press enter",
        "press chris enter": "press enter",
        // select last word
        "select lost word": "select last word",
        "select lost words": "select last word",
        "select last words": "select last word",
        // Bare "escape" stays non-command (content / unclear intent).
    ]

    /// First-token gate for fuzzy match — free dictation rarely starts with these.
    static let commandStarters: Set<String> = [
        "scratch", "scrap", "select", "press", "hit", "cap", "caps", "capital",
        "capitalize", "copy", "paste", "cut", "redo", "undo", "replace",
        "correct", "fix", "spell", "duplicate", "unselect", "deselect",
        "forward", "bold", "italic", "underline", "go", "move", "delete",
        "all", "system",
    ]

    /// Max character edit distance for fuzzy full-utterance match.
    static let maxFuzzyDistance: Int = 1

    /// Soft length bounds for fuzzy (keep free dictation out).
    static let maxFuzzyWords: Int = 5
    static let maxFuzzyChars: Int = 32
    /// Min key length for distance-1 (shorter → exact map/glue only).
    static let minFuzzyChars: Int = 5

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
        // Bounded unique Levenshtein to a command surface (starter-gated).
        if let fuzzy = fuzzyMatch(key) {
            return fuzzy
        }
        return text
    }

    /// Known command surfaces without spaces (for glue repair).
    /// Longest-first match.
    static let commandSurfaces: [String] = [
        "scratch that",
        "select that",
        "select again",
        "select last word",
        "select last sentence",
        "select last paragraph",
        "select last line",
        "select all",
        "press escape",
        "press backspace",
        "press enter",
        "press tab",
        "press space",
        "forward delete",
        "cap that",
        "all caps that",
        "spell that",
        "spell mode",
        "copy that",
        "paste that",
        "cut that",
        "duplicate that",
        "redo that",
        "replace that",
        "undo that",
        "correct that",
        "unselect that",
        "bold that",
        "italic that",
        "underline that",
        "go to start",
        "go to end",
    ]

    static let gluedCommands: [(glued: String, spaced: String)] = {
        commandSurfaces
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

    /// Unique nearest command surface within `maxFuzzyDistance`, or nil.
    /// Requires command-like first token and short full utterance.
    static func fuzzyMatch(_ key: String) -> String? {
        let words = key.split(separator: " ").map(String.init)
        guard !words.isEmpty,
              words.count <= maxFuzzyWords,
              key.count <= maxFuzzyChars,
              key.count >= minFuzzyChars
        else { return nil }

        let first = words[0]
        // Single-token: only allow if exact glue already handled; no fuzzy "hello"→cmd
        if words.count == 1 {
            return nil
        }
        guard isCommandStarter(first) else { return nil }

        var best: String?
        var bestDist = Int.max
        var ties = 0
        for surface in commandSurfaces {
            let d = levenshtein(key, surface)
            guard d <= maxFuzzyDistance else { continue }
            if d < bestDist {
                bestDist = d
                best = surface
                ties = 1
            } else if d == bestDist {
                ties += 1
                best = nil // ambiguous
            }
        }
        guard ties == 1, let winner = best, bestDist > 0 else {
            // dist 0 already matched exact surface — leave to parse; no rewrite needed
            return bestDist == 0 ? best : nil
        }
        return winner
    }

    /// True if `first` is an exact command starter or a 1-edit of a long starter
    /// (≥4 chars) so "slect that" works but "but that" does not match "cut".
    static func isCommandStarter(_ first: String) -> Bool {
        if commandStarters.contains(first) { return true }
        guard first.count >= 4 else { return false }
        for starter in commandStarters where starter.count >= 4 {
            if levenshtein(first, starter) <= 1 { return true }
        }
        return false
    }

    /// Classic Levenshtein distance (characters). Pure; used by fuzzy gate.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        var prev = Array(0...m)
        var cur = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                cur[j] = min(
                    prev[j] + 1,
                    cur[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = cur
        }
        return prev[m]
    }
}
