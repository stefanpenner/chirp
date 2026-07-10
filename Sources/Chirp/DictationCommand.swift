// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// Pure parse; AppState executes against TextInserter + transcript buffer.

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

    /// Parse a post-processed segment into a command, or `.none` for normal text.
    static func parse(_ text: String) -> DictationCommand {
        var n = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Strip trailing sentence punctuation from ASR
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        switch n {
        case "scratch that", "delete that", "undo that",
             "scratch it", "delete it", "undo it",
             "scrap that": // common mis-hear of "scratch"
            return .scratchThat
        case "delete last word", "scratch last word", "scratch word",
             "delete word", "undo word":
            return .deleteLastWord
        case "clear all", "delete all", "scratch all", "clear everything",
             "start over", "delete everything":
            return .clearAll
        case "press enter", "press return", "hit enter", "hit return",
             "press return key":
            return .pressEnter
        case "press tab", "hit tab", "press tab key":
            return .pressTab
        case "copy that", "copy all", "copy it", "copy this":
            return .copyThat
        case "paste that", "paste it", "paste this":
            return .pasteThat
        default:
            return .none
        }
    }

    var isCommand: Bool { self != .none }

    /// User-facing command catalog for Settings / help (say → effect).
    static let helpCatalog: [(say: String, effect: String)] = [
        ("scratch that", "Undo last phrase"),
        ("delete last word", "Remove last word"),
        ("clear all", "Wipe session text"),
        ("press enter", "Insert Return"),
        ("press tab", "Insert Tab"),
        ("copy that", "Copy session to clipboard"),
        ("paste that", "Paste clipboard (⌘V)"),
        ("period / comma / …", "Spoken punctuation"),
        ("new line / new paragraph", "Line breaks"),
        ("dot com / at sign", "Domain & email bits"),
    ]
}
