// CapsMode.swift — Dragon-style capitalization modes for dictation.
// Pure transforms; session stickiness lives in AppState.
// Dual-tested against specs/CapsMode.tla.

import Foundation

/// Sticky capitalization mode for newly committed segments.
enum CapsMode: Equatable, Sendable {
    /// Default ASR casing (plus existing post-process truecase rules).
    case normal
    /// Force lowercase on new text ("no caps on").
    case noCaps
    /// Force UPPERCASE on new text ("all caps on").
    case allCaps
    /// Title-Case Each Word ("caps on").
    case capsOn
}

enum CapsTransform {
    /// Apply sticky mode to a newly committed text segment (not commands).
    static func apply(_ text: String, mode: CapsMode) -> String {
        guard !text.isEmpty else { return text }
        switch mode {
        case .normal:
            return text
        case .noCaps:
            return text.lowercased()
        case .allCaps:
            return text.uppercased()
        case .capsOn:
            return titleCaseWords(text)
        }
    }

    /// Capitalize the first letter of a single word (cap that).
    static func capitalizeWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    /// Title-case each whitespace-delimited word; preserve newlines and spacing.
    static func titleCaseWords(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace || text[i].isNewline {
                result.append(text[i])
                i = text.index(after: i)
                continue
            }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace, !text[i].isNewline {
                i = text.index(after: i)
            }
            let word = String(text[start..<i])
            result.append(capitalizeWord(word))
        }
        return result
    }

    /// UPPERCASE a word, preserving non-letters.
    static func upperWord(_ word: String) -> String {
        word.uppercased()
    }

    /// lowercase a word.
    static func lowerWord(_ word: String) -> String {
        word.lowercased()
    }
}
