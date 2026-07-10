// SpokenListITN.swift — Numbered list voice commands (DictateIt / nVoq style).
//
//   "number one milk next number eggs next number bread"
//     → "\n1. milk\n2. eggs\n3. bread"
//   "end list" / "stop numbering" → resets counter (emits newline)
//
// Counter is session-scoped (reset on new recording). Pure apply() takes
// inout counter so tests stay deterministic. Dual: specs/ListCounter.tla.

import Foundation

enum SpokenListITN {
    private static let wordToNumber: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]

    /// Pattern: "number one" … | "number 3" | "next number" | "number next" | "end list"
    /// Capture groups:
    ///   1 = word number, 2 = digit, 3 = next number, 4 = end list
    /// Leading boundary is lookbehind (not consumed) so consecutive commands still
    /// match after an earlier match eats the trailing space. Trailing `\s*` avoids
    /// double spaces before item text.
    private static let commandPattern: NSRegularExpression = {
        let words = wordToNumber.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern =
            #"(?:(?<=^)|(?<=\s))(?:number\s+(?:("# + words + #")|(\d{1,2}))|(next\s+number|number\s+next)|(end\s+list|stop\s+list|stop\s+numbering|end\s+numbering))\b\s*"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let capitalizeAfterItemPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(\d+\.\s+)([a-z])"#)
    }()

    /// Rewrite list commands; advances `counter` for "next number" and after explicit numbers.
    /// "end list" resets counter to 1.
    static func apply(_ text: String, counter: inout Int) -> String {
        if counter < 1 { counter = 1 }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = commandPattern.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        var planned: [(range: Range<String.Index>, replacement: String)] = []
        var sim = counter
        for match in matches {
            guard let fullRange = Range(match.range, in: text) else { continue }

            // Group 4 = end list / stop numbering (group 3 is "next number")
            if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound {
                sim = 1
                planned.append((fullRange, "\n"))
                continue
            }

            let n: Int
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound,
               let wr = Range(match.range(at: 1), in: text) {
                let word = String(text[wr]).lowercased()
                n = wordToNumber[word] ?? sim
                sim = n + 1
            } else if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                      let dr = Range(match.range(at: 2), in: text),
                      let digit = Int(text[dr]) {
                n = max(1, min(digit, 99))
                sim = n + 1
            } else {
                // Group 3 "next number" / "number next", or fallback
                n = sim
                sim = n + 1
            }
            planned.append((fullRange, "\n\(n). "))
        }

        for item in planned.reversed() {
            result.replaceSubrange(item.range, with: item.replacement)
        }
        counter = sim
        // Drop space left before a leading newline ("buy number one" → "buy\n1. …")
        result = result.replacingOccurrences(of: " \n", with: "\n")
        while result.hasPrefix("\n") {
            result.removeFirst()
        }
        result = capitalizeAfterListMarkers(result)
        return result
    }

    /// Convenience for one-shot strings (counter starts at 1).
    static func apply(_ text: String) -> String {
        var c = 1
        return apply(text, counter: &c)
    }

    /// "1. milk" → "1. Milk"
    private static func capitalizeAfterListMarkers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = capitalizeAfterItemPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let letterRange = Range(match.range(at: 2), in: result) else { continue }
            let letter = String(result[letterRange])
            result.replaceSubrange(letterRange, with: letter.uppercased())
        }
        return result
    }
}
