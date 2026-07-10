// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// "scratch that" / "delete that" undoes the last typed segment.
// Pure parse; AppState executes against TextInserter + transcript buffer.

import Foundation

enum DictationCommand: Equatable, Sendable {
    case none
    /// Undo the most recently typed segment (and its join separator).
    case scratchThat

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
        default:
            return .none
        }
    }

    var isCommand: Bool { self != .none }
}
