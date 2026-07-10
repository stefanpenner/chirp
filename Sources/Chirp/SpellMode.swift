// SpellMode.swift — Dragon/Mac-style sticky spell mode for dictation.
// Pure transforms; session stickiness lives in AppState.
// Dual-tested against specs/SpellMode.tla.

import Foundation

/// Sticky spell mode for newly committed segments.
enum SpellMode: Equatable, Sendable {
    /// Normal dictation (no letter packing).
    case off
    /// Rewrite spoken letters / NATO / digits into packed characters.
    case on

    /// Short HUD label when mode is active; nil when off (hide badge).
    var overlayLabel: String? {
        switch self {
        case .off: return nil
        case .on: return "Spell"
        }
    }
}

enum SpellTransform {
    /// Apply sticky spell mode to a newly committed text segment (not commands).
    static func apply(_ text: String, mode: SpellMode) -> String {
        guard mode == .on, !text.isEmpty else { return text }
        return pack(text)
    }

    /// Pack spoken letter / NATO / digit tokens into characters (shared by sticky mode + one-shot).
    static func pack(_ text: String) -> String {
        packTokens(text)
    }

    /// One-shot whole-utterance: `"spell as a b c"` → `"abc"`. Nil if not a match.
    /// Does not toggle sticky spell mode (caller leaves `spellMode` unchanged).
    static func oneShot(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = oneShotPattern.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 2,
              let restRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let rest = String(trimmed[restRange])
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return pack(rest)
    }

    private static let oneShotPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^spell as\s+(.+)$"#, options: .caseInsensitive)
    }()

    // MARK: - Token packing

    private enum Piece {
        case atom(String)   // letter, digit, punctuation — glue without spaces
        case space          // explicit space token
        case unknown(String)
    }

    private static func packTokens(_ text: String) -> String {
        let raw = text
            .split(whereSeparator: \.isWhitespace)
            .map { stripTrailingPunct(String($0)) }
            .filter { !$0.isEmpty }

        var pieces: [Piece] = []
        var i = 0
        while i < raw.count {
            let t = raw[i].lowercased()

            // "capital X" / "upper X"
            if (t == "capital" || t == "upper"), i + 1 < raw.count {
                if let ch = letterValue(raw[i + 1]) {
                    pieces.append(.atom(String(ch).uppercased()))
                    i += 2
                    continue
                }
            }

            // "space bar"
            if t == "space", i + 1 < raw.count, raw[i + 1].lowercased() == "bar" {
                pieces.append(.space)
                i += 2
                continue
            }

            if t == "space" {
                pieces.append(.space)
                i += 1
                continue
            }

            if let ch = letterValue(raw[i]) {
                pieces.append(.atom(String(ch)))
                i += 1
                continue
            }

            if let d = digitValue(t) {
                pieces.append(.atom(d))
                i += 1
                continue
            }

            if t == "period" || t == "dot" {
                pieces.append(.atom("."))
                i += 1
                continue
            }

            pieces.append(.unknown(raw[i]))
            i += 1
        }

        return joinPieces(pieces)
    }

    private static func joinPieces(_ pieces: [Piece]) -> String {
        var result = ""
        var lastWasAtom = false

        for piece in pieces {
            switch piece {
            case .atom(let s):
                if !lastWasAtom, !result.isEmpty, !result.hasSuffix(" ") {
                    result.append(" ")
                }
                result.append(s)
                lastWasAtom = true
            case .space:
                result.append(" ")
                lastWasAtom = false
            case .unknown(let w):
                if !result.isEmpty, !result.hasSuffix(" ") {
                    result.append(" ")
                }
                result.append(w)
                lastWasAtom = false
            }
        }
        return result
    }

    private static func stripTrailingPunct(_ s: String) -> String {
        var n = s
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        return n
    }

    /// Map a single token to a lowercase letter, or nil if not a letter token.
    private static func letterValue(_ token: String) -> Character? {
        let t = token.lowercased()
        // Single spoken letter "a"…"z"
        if t.count == 1, let c = t.first, c.isLetter, c.isASCII {
            return c
        }
        return natoTable[t]
    }

    private static func digitValue(_ t: String) -> String? {
        switch t {
        case "zero", "oh": return "0"
        case "one": return "1"
        case "two": return "2"
        case "three": return "3"
        case "four": return "4"
        case "five": return "5"
        case "six": return "6"
        case "seven": return "7"
        case "eight": return "8"
        case "nine": return "9"
        default: return nil
        }
    }

    /// NATO phonetic alphabet (and common spellings).
    private static let natoTable: [String: Character] = [
        "alpha": "a", "alfa": "a",
        "bravo": "b",
        "charlie": "c",
        "delta": "d",
        "echo": "e",
        "foxtrot": "f",
        "golf": "g",
        "hotel": "h",
        "india": "i",
        "juliet": "j", "juliett": "j",
        "kilo": "k",
        "lima": "l",
        "mike": "m",
        "november": "n",
        "oscar": "o",
        "papa": "p",
        "quebec": "q",
        "romeo": "r",
        "sierra": "s",
        "tango": "t",
        "uniform": "u",
        "victor": "v",
        "whiskey": "w",
        "xray": "x", "x-ray": "x",
        "yankee": "y",
        "zulu": "z",
    ]
}
