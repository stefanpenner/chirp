// SpokenListITN.swift — Numbered list voice commands (DictateIt / nVoq style).
//
//   "number one milk next number eggs next number bread"
//     → "\n1. milk\n2. eggs\n3. bread"
//   "number twenty one milk" → "\n21. milk"
//   "number two hundred five" → "\n205. "
//   "number one thousand two hundred thirty one" → "\n1231. "
//   "number one million" → "\n1000000. "
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
        "thirty": 30, "forty": 40, "fourty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let tensWords: Set<String> = [
        "twenty", "thirty", "forty", "fourty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    private static let unitWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    ]

    /// Command lead only — number body parsed by `parseListCardinal`.
    /// Groups: 1 = next number / number next, 2 = end list, 3 = bare "number "
    /// (order matters: "number next" must win over bare "number").
    private static let commandLeadPattern: NSRegularExpression = {
        let pattern =
            #"(?:(?<=^)|(?<=\s))(?:(next\s+number|number\s+next)|(end\s+list|stop\s+list|stop\s+numbering|end\s+numbering)|(number)\s+)\b\s*"#
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
        let leads = commandLeadPattern.matches(in: text, range: nsRange)
        guard !leads.isEmpty else { return text }

        var result = text
        var sim = counter
        // Process left-to-right for counter; replace right-to-left for indices.
        var ordered: [(range: Range<String.Index>, replacement: String, nextSim: Int)] = []
        var local = sim

        for match in leads {
            guard let leadRange = Range(match.range, in: text) else { continue }

            // Group 1 = next number / number next
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let n = local
                local = n + 1
                ordered.append((leadRange, "\n\(n). ", local))
                continue
            }

            // Group 2 = end list
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                local = 1
                ordered.append((leadRange, "\n", local))
                continue
            }

            // Group 3 = bare "number " — parse cardinal after the lead
            let afterLead = leadRange.upperBound
            let tail = String(text[afterLead...])
            let tokens = tokenize(tail)
            if let (n, consumed) = parseListCardinal(tokens, start: 0), consumed > 0 {
                let consumedEnd = endIndex(
                    ofFirst: consumed,
                    tokens: tokens,
                    in: tail,
                    base: afterLead,
                    text: text
                )
                let fullRange = leadRange.lowerBound..<consumedEnd
                let val = min(max(n, 1), listCardinalMax)
                local = val + 1
                ordered.append((fullRange, "\n\(val). ", local))
            }
            // If "number" with no parseable body, leave text alone (no rewrite).
        }

        sim = local
        // Right-to-left so earlier ranges stay valid in `result`.
        for item in ordered.reversed() {
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

    // MARK: - Cardinal parse (1…9_999_999)

    private static let listCardinalMax = 9_999_999

    /// Tokenize on whitespace and hyphens so "twenty-one" → ["twenty","one"].
    private static func tokenize(_ s: String) -> [String] {
        s.split { $0.isWhitespace || $0 == "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func core(_ w: String) -> String {
        w.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Parse list cardinal at `tokens[start…]` → (value, tokens consumed).
    private static func parseListCardinal(_ tokens: [String], start: Int) -> (Int, Int)? {
        guard start < tokens.count else { return nil }
        let c0 = core(tokens[start])

        // Digit form 1…listCardinalMax
        if let d = Int(c0), d >= 1, d <= listCardinalMax, c0.allSatisfy(\.isNumber) {
            return (d, 1)
        }

        // N million [and]? [rest below million]
        if unitWords.contains(c0), start + 1 < tokens.count, core(tokens[start + 1]) == "million" {
            var val = (wordToNumber[c0] ?? 1) * 1_000_000
            var i = start + 2
            if i < tokens.count, core(tokens[i]) == "and" { i += 1 }
            if let (rest, n) = parseBelowMillion(tokens, start: i) {
                val += rest
                i += n
            }
            return (min(val, listCardinalMax), i - start)
        }

        if let (below, n) = parseBelowMillion(tokens, start: start) {
            return (below, n)
        }
        return nil
    }

    /// 1…999_999: N thousand [and]? rest | below-thousand
    private static func parseBelowMillion(_ tokens: [String], start: Int) -> (Int, Int)? {
        guard start < tokens.count else { return nil }
        let c0 = core(tokens[start])

        if unitWords.contains(c0), start + 1 < tokens.count, core(tokens[start + 1]) == "thousand" {
            var val = (wordToNumber[c0] ?? 1) * 1000
            var i = start + 2
            if i < tokens.count, core(tokens[i]) == "and" { i += 1 }
            if let (rest, n) = parseBelowThousand(tokens, start: i) {
                val += rest
                i += n
            }
            return (min(val, 999_999), i - start)
        }

        return parseBelowThousand(tokens, start: start)
    }

    /// 1…999: N hundred [and]? rest | tens [unit] | single word | fail
    private static func parseBelowThousand(_ tokens: [String], start: Int) -> (Int, Int)? {
        guard start < tokens.count else { return nil }
        let c0 = core(tokens[start])

        // N hundred [and]? [tens unit | singles]
        if unitWords.contains(c0), start + 1 < tokens.count, core(tokens[start + 1]) == "hundred" {
            var val = (wordToNumber[c0] ?? 1) * 100
            var i = start + 2
            if i < tokens.count, core(tokens[i]) == "and" { i += 1 }
            if let (rest, n) = parseTensOrSingle(tokens, start: i) {
                val += rest
                i += n
            }
            return (min(val, 999), i - start)
        }

        return parseTensOrSingle(tokens, start: start)
    }

    /// Tens (+ optional unit) or single teen/unit/ten word.
    private static func parseTensOrSingle(_ tokens: [String], start: Int) -> (Int, Int)? {
        guard start < tokens.count else { return nil }
        let c0 = core(tokens[start])

        if tensWords.contains(c0), let tens = wordToNumber[c0] {
            if start + 1 < tokens.count {
                let c1 = core(tokens[start + 1])
                if unitWords.contains(c1), let u = wordToNumber[c1] {
                    return (tens + u, 2)
                }
            }
            return (tens, 1)
        }

        if let v = wordToNumber[c0], !tensWords.contains(c0) {
            return (v, 1)
        }
        return nil
    }

    /// Map first `count` tokens in `tail` back to an index in the original `text`.
    private static func endIndex(
        ofFirst count: Int,
        tokens: [String],
        in tail: String,
        base: String.Index,
        text: String
    ) -> String.Index {
        guard count > 0, count <= tokens.count else { return base }
        var searchFrom = tail.startIndex
        var lastEnd = tail.startIndex
        for k in 0..<count {
            let tok = tokens[k]
            if let r = tail.range(
                of: tok,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchFrom..<tail.endIndex
            ) {
                lastEnd = r.upperBound
                searchFrom = r.upperBound
                // Skip hyphen in "twenty-one"
                if k + 1 < count, searchFrom < tail.endIndex, tail[searchFrom] == "-" {
                    searchFrom = tail.index(after: searchFrom)
                }
            } else {
                break
            }
        }
        // Trailing whitespace after the last number token (matches prior `\s*`).
        while lastEnd < tail.endIndex, tail[lastEnd].isWhitespace {
            lastEnd = tail.index(after: lastEnd)
        }
        let offset = tail.distance(from: tail.startIndex, to: lastEnd)
        return text.index(base, offsetBy: offset)
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
