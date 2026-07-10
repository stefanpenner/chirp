// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// Pure parse; AppState executes against TextInserter + transcript buffer.
// Tolerant of ASR trailing punctuation, politeness words, and common aliases.

import Foundation

enum DictationCommand: Equatable, Sendable {
    case none
    /// Undo the most recently typed segment (and its join separator).
    case scratchThat
    /// Arm multi-step replace: next content undoes last phrase then inserts.
    case replaceThat
    /// Delete the last whitespace-delimited word.
    case deleteLastWord
    /// Clear the entire session transcript and typed text.
    case clearAll
    /// Insert a newline (Return key).
    case pressEnter
    /// Insert a tab.
    case pressTab
    /// Press Backspace / Delete once. Keyboard-only; buffer unchanged.
    case pressBackspace
    /// Copy session transcript to the clipboard.
    case copyThat
    /// Paste from the clipboard into the focused app.
    case pasteThat
    /// Redo the last scratched segment.
    case redoThat
    /// Set sticky capitalization mode for following commits.
    case setCapsMode(CapsMode)
    /// Set sticky spell mode for following commits (letter packing).
    case setSpellMode(SpellMode)
    /// Select last phrase and enter spell mode (Dragon-style "spell that").
    case spellThat
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
    /// Select the last typed phrase (shift+left over last stack delta).
    case selectThat
    /// Select the last whitespace-delimited word.
    case selectLastWord
    /// Select all in the focused app (⌘A).
    case selectAll
    /// Move cursor one word left (⌥←). Buffer unchanged.
    case moveLeftWord
    /// Move cursor one word right (⌥→). Buffer unchanged.
    case moveRightWord
    /// Move cursor to line start (⌘←). Buffer unchanged.
    case moveToStart
    /// Move cursor to line end (⌘→). Buffer unchanged.
    case moveToEnd

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
             "go back", "go back that",
             // Immediate undo synonyms
             "correct that", "fix that",
             "correct it", "fix it":
            return .scratchThat
        case "replace that", "replace it", "replace last",
             "swap that", "change that":
            return .replaceThat
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
        // Keyboard backspace only — do not match "delete that" / "delete it"
        // (those remain scratchThat) or "delete last" (deleteLastWord).
        case "press backspace", "hit backspace", "backspace",
             "press delete", "hit delete", "delete key":
            return .pressBackspace
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
        // Sticky spell mode (Dragon / Mac-style letter packing)
        // Off phrases listed before bare "spell mode" so exact match wins.
        case "spell mode off", "spell off", "end spell", "end spelling",
             "dictation mode":
            return .setSpellMode(.off)
        case "spell mode", "spelling mode", "start spelling", "spell on":
            return .setSpellMode(.on)
        // Select last phrase + enter spell mode (does not delete text)
        case "spell that", "spell it", "spell last":
            return .spellThat
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
        case "select that", "select it", "select last", "highlight that",
             "highlight it", "highlight last":
            return .selectThat
        case "select last word", "highlight last word",
             "select the last word", "highlight the last word":
            return .selectLastWord
        case "select all", "highlight all", "select everything":
            return .selectAll
        case "move left", "left word", "previous word", "go left",
             "back one word":
            return .moveLeftWord
        case "move right", "right word", "next word", "go right",
             "forward one word":
            return .moveRightWord
        case "go to start", "go to beginning", "beginning of line":
            return .moveToStart
        case "go to end", "end of line":
            return .moveToEnd
        default:
            return nil
        }
    }

    var isCommand: Bool { self != .none }

    /// User-facing command catalog for Settings / help (say → effect).
    static let helpCatalog: [(say: String, effect: String)] = [
        ("scratch that / correct that", "Undo last phrase (multi-level)"),
        ("replace that", "Next phrase replaces last (multi-step)"),
        ("redo that", "Restore last scratched phrase"),
        ("delete last word", "Remove last word"),
        ("clear all", "Wipe session text"),
        ("press enter", "Insert Return"),
        ("press tab", "Insert Tab"),
        ("press backspace / delete key", "Press Backspace once (keyboard only)"),
        ("copy that", "Copy session to clipboard"),
        ("paste that", "Paste clipboard (⌘V)"),
        ("caps on / all caps on / no caps on", "Sticky capitalization mode"),
        ("caps off", "Back to normal casing"),
        ("spell mode / start spelling", "Sticky spell mode (letter packing)"),
        ("spell off / end spelling / dictation mode", "Exit spell mode"),
        ("spell that", "Select last phrase + enter spell mode"),
        ("cap that / all caps that", "Transform last word"),
        ("title case that", "Title-case last phrase"),
        ("sentence case that", "Sentence-case last phrase"),
        ("no space that", "Join last word without space"),
        ("select that", "Select last phrase"),
        ("select last word", "Select last word"),
        ("select all", "Select all (⌘A)"),
        ("move left / previous word", "Cursor left one word (⌥←)"),
        ("move right / next word", "Cursor right one word (⌥→)"),
        ("go to start / beginning of line", "Cursor to line start (⌘←)"),
        ("go to end / end of line", "Cursor to line end (⌘→)"),
        ("period / comma / …", "Spoken punctuation"),
        ("new line / new paragraph", "Line breaks"),
        ("bullet point / next bullet", "Bulleted list item"),
        ("number one / next number", "Numbered list item"),
        ("end list / stop numbering", "Reset list counter"),
        ("dot com / at sign", "Domain & email bits"),
    ]
}
