// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// Pure parse; AppState executes against TextInserter + transcript buffer.
// Tolerant of ASR trailing punctuation, politeness words, and common aliases.

import Foundation

enum DictationCommand: Equatable, Sendable {
    case none
    /// Undo the most recently typed segment (and its join separator).
    case scratchThat
    /// Delete the last whitespace-delimited word.
    case deleteLastWord
    /// Clear the entire session transcript and typed text.
    case clearAll
    /// Insert a newline (Return key).
    case pressEnter
    /// Insert a tab.
    case pressTab
    /// Copy session transcript to the clipboard.
    case copyThat
    /// Paste from the clipboard into the focused app.
    case pasteThat
    /// Redo the last scratched segment.
    case redoThat
    /// Set sticky capitalization mode for following commits.
    case setCapsMode(CapsMode)
    /// Capitalize the last word (one-shot).
    case capThat
    /// UPPERCASE the last word (one-shot).
    case allCapsThat
    /// lowercase the last word (one-shot).
    case noCapsThat
    /// Title-case the last phrase / stack delta (one-shot).
    case titleCaseThat
    /// Sentence-case the last phrase (one-shot).
    case sentenceCaseThat
    /// Remove the space before the last word / phrase (one-shot).
    case noSpaceThat

    /// Parse a post-processed segment into a command, or `.none` for normal text.
    static func parse(_ text: String) -> DictationCommand {
        let candidates = normalizeCandidates(text)
        for candidate in candidates {
            if let cmd = matchExact(candidate) {
                return cmd
            }
        }
        return .none
    }

    /// Build match candidates: raw normalize, then strip politeness fillers.
    private static func normalizeCandidates(_ text: String) -> [String] {
        var n = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Strip trailing sentence punctuation from ASR
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Collapse internal whitespace
        n = n.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        var out: [String] = []
        if !n.isEmpty { out.append(n) }

        let stripped = stripPoliteness(n)
        if stripped != n, !stripped.isEmpty {
            out.append(stripped)
        }
        return out
    }

    /// Drop leading/trailing politeness that ASR often glues onto commands.
    private static func stripPoliteness(_ s: String) -> String {
        var tokens = s.split(separator: " ").map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first) {
            tokens.removeFirst()
        }
        // "thank you" already handled token-wise; drop trailing fillers
        while let last = tokens.last, fillers.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static func matchExact(_ n: String) -> DictationCommand? {
        switch n {
        case "scratch that", "delete that", "undo that",
             "scratch it", "delete it", "undo it",
             "scrap that", // common mis-hear of "scratch"
             "scratch hat", // ASR near-miss
             "go back", "go back that":
            return .scratchThat
        case "delete last word", "scratch last word", "scratch word",
             "delete word", "undo word",
             "delete the last word", "scratch the last word",
             "delete last", "scratch last",
             "remove last word", "remove the last word":
            return .deleteLastWord
        case "clear all", "delete all", "scratch all", "clear everything",
             "start over", "delete everything", "clear it all",
             "wipe all", "wipe everything":
            return .clearAll
        case "press enter", "press return", "hit enter", "hit return",
             "press return key", "press the enter key", "hit the enter key":
            return .pressEnter
        case "press tab", "hit tab", "press tab key", "press the tab key":
            return .pressTab
        case "copy that", "copy all", "copy it", "copy this", "copy the text":
            return .copyThat
        case "paste that", "paste it", "paste this", "paste here":
            return .pasteThat
        case "redo that", "redo it", "restore that", "undo undo",
             "redo last", "put it back":
            return .redoThat
        // Sticky caps modes (Dragon-style)
        case "no caps on", "no caps mode":
            return .setCapsMode(.noCaps)
        case "all caps on", "all caps mode", "all caps":
            return .setCapsMode(.allCaps)
        case "caps on", "cap on", "title case on":
            return .setCapsMode(.capsOn)
        case "caps off", "cap off", "no caps off", "all caps off",
             "normal caps", "normal case", "default caps":
            return .setCapsMode(.normal)
        // One-shot last-word transforms
        case "cap that", "capitalize that", "caps that", "capital that":
            return .capThat
        case "all caps that", "uppercase that", "upper case that":
            return .allCapsThat
        case "no caps that", "lowercase that", "lower case that":
            return .noCapsThat
        case "title case that", "title case that phrase", "titlecase that",
             "title case phrase":
            return .titleCaseThat
        case "sentence case that", "sentence case that phrase",
             "sentencecase that":
            return .sentenceCaseThat
        case "no space that", "nospace that", "no spaces that",
             "delete the space", "remove the space":
            return .noSpaceThat
        default:
            return nil
        }
    }

    var isCommand: Bool { self != .none }

    /// User-facing command catalog for Settings / help (say → effect).
    static let helpCatalog: [(say: String, effect: String)] = [
        ("scratch that", "Undo last phrase (multi-level)"),
        ("redo that", "Restore last scratched phrase"),
        ("delete last word", "Remove last word"),
        ("clear all", "Wipe session text"),
        ("press enter", "Insert Return"),
        ("press tab", "Insert Tab"),
        ("copy that", "Copy session to clipboard"),
        ("paste that", "Paste clipboard (⌘V)"),
        ("caps on / all caps on / no caps on", "Sticky capitalization mode"),
        ("caps off", "Back to normal casing"),
        ("cap that / all caps that", "Transform last word"),
        ("title case that", "Title-case last phrase"),
        ("sentence case that", "Sentence-case last phrase"),
        ("no space that", "Join last word without space"),
        ("period / comma / …", "Spoken punctuation"),
        ("new line / new paragraph", "Line breaks"),
        ("dot com / at sign", "Domain & email bits"),
    ]
}
