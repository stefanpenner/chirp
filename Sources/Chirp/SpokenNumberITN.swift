// SpokenNumberITN.swift — Light inverse text normalization for cardinal numbers.
// Converts multi-token spoken numbers to digits without a full WFST grammar.
//
// Safe by design:
// - Bare "one"/"two"/… alone are NOT converted ("one more thing" stays)
// - Needs compound (twenty five), teen, magnitude (hundred/thousand), or "point"
// Dual-tested via TextPostProcessorTests (no TLA — pure String→String).

import Foundation

enum SpokenNumberITN {
    private static let units: [String: Int] = [
        "zero": 0, "oh": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let magnitudes: [String: Int] = [
        "hundred": 100,
        "thousand": 1_000,
        "million": 1_000_000,
    ]

    private static let numberWords: Set<String> = {
        var s = Set(units.keys)
        s.formUnion(tens.keys)
        s.formUnion(magnitudes.keys)
        s.insert("and")
        s.insert("point")
        return s
    }()

    /// Rewrite multi-token spoken numbers in `text` to digit form.
    static func apply(_ text: String) -> String {
        // Tokenize preserving separators (spaces/punct) via simple split on whitespace
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return text }

        var out: [String] = []
        var i = 0
        while i < parts.count {
            let token = parts[i]
            let core = normalizeToken(token)
            if core.isEmpty {
                out.append(token)
                i += 1
                continue
            }
            if numberWords.contains(core) {
                // Collect consecutive number-ish tokens (skip empty/punct-only gaps? keep simple: only space-split tokens)
                var j = i
                var words: [String] = []
                while j < parts.count {
                    let c = normalizeToken(parts[j])
                    if c.isEmpty {
                        // empty from double spaces — stop number run
                        break
                    }
                    if numberWords.contains(c) {
                        words.append(c)
                        j += 1
                    } else {
                        break
                    }
                }
                if let value = parsePhrase(words), shouldConvert(words) {
                    // Preserve trailing punctuation from last token of the span
                    let lastRaw = parts[j - 1]
                    let trailing = trailingPunctuation(lastRaw)
                    out.append(formatValue(value) + trailing)
                    i = j
                    continue
                }
            }
            out.append(token)
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Parse a phrase of number words into a numeric value, or nil if invalid.
    static func parsePhrase(_ words: [String]) -> Double? {
        guard !words.isEmpty else { return nil }

        // Decimal: N point M  (M is digit sequence as fractional)
        if let pointIdx = words.firstIndex(of: "point"), pointIdx > 0 {
            let left = Array(words[..<pointIdx])
            let right = Array(words[(pointIdx + 1)...])
            guard let whole = parseIntegerPhrase(left), !right.isEmpty else { return nil }
            var frac = ""
            for w in right {
                if let u = units[w], u < 10 {
                    frac.append(String(u))
                } else if let t = tens[w] {
                    frac.append(String(t))
                } else {
                    return nil
                }
            }
            guard let fracNum = Double("0." + frac) else { return nil }
            return Double(whole) + fracNum
        }

        if let intVal = parseIntegerPhrase(words) {
            return Double(intVal)
        }
        return nil
    }

    // MARK: - Internals

    private static func shouldConvert(_ words: [String]) -> Bool {
        if words.count >= 2 { return true }
        guard let w = words.first else { return false }
        // Single token: only teens / tens / magnitudes (not bare one–twelve)
        if tens[w] != nil { return true }
        if magnitudes[w] != nil { return true }
        if let u = units[w], u >= 13 { return true } // teens
        return false
    }

    private static func parseIntegerPhrase(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0
        var current = 0
        var sawNumber = false

        for w in words {
            if w == "and" {
                continue // "one hundred and five"
            }
            if let u = units[w] {
                current += u
                sawNumber = true
            } else if let t = tens[w] {
                current += t
                sawNumber = true
            } else if let mag = magnitudes[w] {
                if current == 0 { current = 1 } // "hundred" alone → 100
                current *= mag
                if mag >= 1000 {
                    total += current
                    current = 0
                }
                sawNumber = true
            } else {
                return nil
            }
        }
        guard sawNumber else { return nil }
        return total + current
    }

    private static func formatValue(_ value: Double) -> String {
        if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        // Trim trailing zeros for decimals
        var s = String(value)
        if s.contains(".") {
            while s.last == "0" { s.removeLast() }
            if s.last == "." { s.removeLast() }
        }
        return s
    }

    private static func normalizeToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }

    private static func trailingPunctuation(_ token: String) -> String {
        var suffix = ""
        for ch in token.reversed() {
            if ch.isPunctuation || ch == "," || ch == "." || ch == "!" || ch == "?" {
                suffix = String(ch) + suffix
            } else {
                break
            }
        }
        return suffix
    }
}
