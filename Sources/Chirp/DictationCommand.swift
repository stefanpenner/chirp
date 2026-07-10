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
        default:
            return .none
        }
    }

    var isCommand: Bool { self != .none }
}
