// SpokenListITN.swift — Numbered list voice commands (DictateIt / nVoq style).
//
//   "number one milk next number eggs next number bread"
//     → "\n1. milk\n2. eggs\n3. bread"
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

    /// Pattern: "number one" … "number twenty" | "number 3" | "next number" | "number next"
    private static let commandPattern: NSRegularExpression = {
        let words = wordToNumber.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern =
            #"(?:^|\s+)(?:number\s+(?:("# + words + #")|(\d{1,2}))|(next\s+number|number\s+next))\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Rewrite list commands; advances `counter` for "next number" and after explicit numbers.
    static func apply(_ text: String, counter: inout Int) -> String {
        if counter < 1 { counter = 1 }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = commandPattern.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        // Left-to-right so counter advances in speech order; apply reversed for indices.
        var planned: [(range: Range<String.Index>, replacement: String)] = []
        var sim = counter
        for match in matches {
            guard let fullRange = Range(match.range, in: text) else { continue }
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
                // next number / number next
                n = sim
                sim = n + 1
            }
            planned.append((fullRange, "\n\(n). "))
        }

        for item in planned.reversed() {
            result.replaceSubrange(item.range, with: item.replacement)
        }
        counter = sim
        if result.hasPrefix("\n") {
            result.removeFirst()
        }
        return result
    }

    /// Convenience for one-shot strings (counter starts at 1).
    static func apply(_ text: String) -> String {
        var c = 1
        return apply(text, counter: &c)
    }
}
