// SpokenNumberITN.swift — Light inverse text normalization for cardinals + ordinals.
// Converts multi-token spoken numbers to digits without a full WFST grammar.
//
// Safe by design:
// - Bare "one"/"two"/… alone are NOT converted ("one more thing" stays)
// - Needs compound (twenty five), teen, magnitude (hundred/thousand), or "point"
// - Exception: bare units before quantity nouns → digits ("five emails" → "5 emails")
// - Digit runs: ≥3 consecutive single-digit units → concatenate ("five five five" → "555")
//   Short pure runs ("one two") stay words; "oh"/"o" → 0 (leading zeros kept)
//   "double five" / "triple oh" expand inside a run (phone dictation)
//   Bare phone-length digit tokens from ASR ("5551212") get dash formatting
//   "N dozen" → N×12; "a dozen" / "half (a) dozen" → 12 / 6
//   Exception: after suite/room/floor/chapter/gate/… cues, digit runs of ≥1 convert
// - Negatives: "minus"/"negative" + number phrase → "-N" (not bare "minus" / "minus sign")
// - Ordinals: "first" blocked before of/all/class; "twenty first" → 21st always
// Dual-tested via SpokenNumberITNTests (no TLA — pure String→String).

import Foundation

enum SpokenNumberITN {
    /// Cues that force bare-unit + short digit-run conversion (address / version / media).
    private static let forceNumberCues: Set<String> = [
        "suite", "apartment", "apt", "unit", "room", "floor", "extension", "ext",
        "version",
        // Free-dict labels: "chapter five", "gate twelve", "pin four five six seven"
        "chapter", "page", "gate", "aisle", "channel", "episode", "season",
        "pin", "code",
    ]

    /// Count nouns after a number force bare-unit conversion ("ten items" → "10 items").
    /// Safer set only — skip ambiguous next words (of, more, times, point, birds…).
    /// Frequency uses a separate pattern (`N times a day`), not bare "times".
    private static let quantityNouns: Set<String> = [
        "item", "items",
        "email", "emails",
        "person", "people",
        "copy", "copies",
        "file", "files",
        "message", "messages",
        "page", "pages",
        "ticket", "tickets",
        "seat", "seats",
        "user", "users",
        "apple", "apples",
        "orange", "oranges",
        // Dictation staples (safe count nouns; not of/more/times)
        "note", "notes",
        "task", "tasks",
        "meeting", "meetings",
        "bug", "bugs",
        "line", "lines",
        "word", "words",
        "commit", "commits",
        "document", "documents",
        "hour", "hours",
        "minute", "minutes",
        "second", "seconds",
        "day", "days",
        "week", "weeks",
        "month", "months",
        "year", "years",
        "comment", "comments",
        "issue", "issues",
        "request", "requests",
        "change", "changes",
        "paragraph", "paragraphs",
        "sentence", "sentences",
    ]

    /// Periods for "N times a/an <period>" frequency ITN.
    private static let frequencyPeriods: Set<String> = [
        "day", "week", "month", "hour", "year", "minute", "second",
    ]
    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, // bare "o" — ASR often drops h from "oh"
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    /// Phone-style repeaters: "double five" → five five; "triple oh" → oh oh oh.
    private static let digitRepeaters: [String: Int] = [
        "double": 2,
        "triple": 3,
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

    /// Single-word ordinals → cardinal value (suffix applied later).
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1_000,
    ]

    /// Unit part of compound ordinals: twenty first → 21st
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]

    /// After bare first/second/third, do not convert (discourse / idioms).
    private static let ordinalBlockNext: Set<String> = [
        "of", "all", "class", "person", "aid", "responder", "lady", "gentleman",
        "mate", "base", "hand", "light", "name", "draft", "impression",
        "glance", "place", // "first place" kept as words? actually 1st place is fine
        "priority", "thing", "things", "time", // "first time" often better as words
        "step", "steps", "round", // keep conversational
    ]

    private static let numberWords: Set<String> = {
        var s = Set(units.keys)
        s.formUnion(tens.keys)
        s.formUnion(magnitudes.keys)
        s.insert("and")
        s.insert("point")
        return s
    }()

    /// Rewrite multi-token spoken numbers and safe ordinals in `text`.
    static func apply(_ text: String) -> String {
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

            // Negative: "minus twenty" / "negative five" → "-20" / "-5"
            // Only when followed by a convertible number phrase (not bare "minus" / "minus sign").
            if core == "minus" || core == "negative" {
                if let rewritten = tryConsumeSignedNumber(parts: parts, start: i + 1) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
            }

            // Compound ordinal: twenty first → 21st
            if let t = tens[core], i + 1 < parts.count {
                let nextCore = normalizeToken(parts[i + 1])
                if let u = ordinalUnits[nextCore] {
                    let value = t + u
                    let trailing = trailingPunctuation(parts[i + 1])
                    out.append(formatOrdinal(value) + trailing)
                    i += 2
                    continue
                }
            }

            // Single ordinal word with discourse guard
            if let ord = ordinals[core] {
                let nextCore = (i + 1 < parts.count) ? normalizeToken(parts[i + 1]) : ""
                if shouldConvertOrdinal(value: ord, word: core, next: nextCore) {
                    let trailing = trailingPunctuation(token)
                    out.append(formatOrdinal(ord) + trailing)
                    i += 1
                    continue
                }
            }

            // once/twice a|per <period> → "1 time a day" / "2 times a week"
            if core == "once" || core == "twice" {
                if let rewritten = tryConsumeOnceTwiceFrequency(parts: parts, start: i) {
                    out.append(contentsOf: rewritten.tokens)
                    i = rewritten.nextIndex
                    continue
                }
            }

            // half (a) dozen → 6; a dozen → 12 (not numberWords openers)
            if core == "half" {
                if let rewritten = tryConsumeHalfDozen(parts: parts, start: i) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
            }
            if core == "a" {
                if let rewritten = tryConsumeADozen(parts: parts, start: i) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
                if let rewritten = tryConsumeCoupleOrPairOf(parts: parts, start: i) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
            }
            // "couple of" / "pair of" without leading "a"
            if core == "couple" || core == "pair" {
                if let rewritten = tryConsumeCoupleOrPairOf(parts: parts, start: i) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
            }
            // After phraseFixes: "2½ dozen" → 30
            if let n = unicodeHalfValue(core),
               i + 1 < parts.count,
               normalizeToken(parts[i + 1]) == "dozen"
            {
                let trailing = trailingPunctuation(parts[i + 1])
                out.append(formatValue(Double(n * 12 + 6)) + trailing)
                i += 2
                continue
            }

            // Cardinal multi-token / teen / decade / digit-run
            // "double"/"triple" start phone-style runs (not bare numberWords).
            // Digit tokens ("6 and a half") also open when followed by and-a-half / dozen.
            let digitOpensHalf =
                core.allSatisfy(\.isNumber)
                && i + 1 < parts.count
                && normalizeToken(parts[i + 1]) == "and"
            if numberWords.contains(core) || digitRepeaters[core] != nil || digitOpensHalf {
                let prevCore = i > 0 ? normalizeToken(parts[i - 1]) : ""
                let afterCue = forceNumberCues.contains(prevCore)
                if let rewritten = tryConsumeCardinal(
                    parts: parts,
                    start: i,
                    forceConvert: afterCue,
                    // After suite/room/floor/ext/version: bare "five" → "5"; runs "five five" → "55"
                    digitRunMinLength: afterCue ? 1 : 3
                ) {
                    out.append(rewritten.text)
                    i = rewritten.nextIndex
                    continue
                }
            }

            // ASR often emits a phone-length digit blob ("5551212") without dashes.
            if let phone = formatBarePhoneToken(core) {
                out.append(phone + trailingPunctuation(token))
                i += 1
                continue
            }

            out.append(token)
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Format a single token of pure digits when it looks like a phone number.
    /// 7 / 10 / 11-with-leading-1 only — years (4) and short codes stay plain.
    static func formatBarePhoneToken(_ core: String) -> String? {
        guard !core.isEmpty, core.allSatisfy(\.isNumber) else { return nil }
        let formatted = formatPhoneDigits(core)
        // Only rewrite when dashes were actually added.
        guard formatted != core else { return nil }
        return formatted
    }

    /// Consume a number phrase after "minus"/"negative"; bare units convert when signed.
    private static func tryConsumeSignedNumber(
        parts: [String], start: Int
    ) -> (text: String, nextIndex: Int)? {
        guard start < parts.count else { return nil }
        // Signed: bare units + digit runs of length ≥1
        guard let rewritten = tryConsumeCardinal(
            parts: parts, start: start, forceConvert: true, digitRunMinLength: 1
        )
        else { return nil }
        return ("-" + rewritten.text, rewritten.nextIndex)
    }

    /// Scan a run of number words from `start` and convert when allowed.
    /// `forceConvert` allows bare units (signed / after address or version cues).
    /// Quantity nouns after the run also force bare-unit convert ("five emails" → "5 emails").
    /// `digitRunMinLength` is 3 by default (phone), 1 after suite/room/floor/ext/version, 1 when signed.
    private static func tryConsumeCardinal(
        parts: [String],
        start: Int,
        forceConvert: Bool,
        digitRunMinLength: Int = 3
    ) -> (text: String, nextIndex: Int)? {
        var j = start
        var words: [String] = []
        while j < parts.count {
            let c = normalizeToken(parts[j])
            if c.isEmpty { break }
            // "double five" / "triple oh" → expand into single-digit units
            if let reps = digitRepeaters[c] {
                guard j + 1 < parts.count else { break }
                let next = normalizeToken(parts[j + 1])
                // Only expand when next is a single digit (0–9), not "double check"
                guard let u = units[next], u < 10 else { break }
                for _ in 0..<reps {
                    words.append(next)
                }
                j += 2
                continue
            }
            if c == "and" {
                // Only consume "and" inside compounds ("one hundred and five").
                // Stop before "two and a half" so and-a-half can match.
                guard j + 1 < parts.count else { break }
                let nxt = normalizeToken(parts[j + 1])
                guard numberWords.contains(nxt) || units[nxt] != nil || tens[nxt] != nil
                        || magnitudes[nxt] != nil
                else { break }
                // Skip "and" without storing (parseIntegerPhrase also skips it)
                j += 1
                continue
            }
            // Digit whole numbers: "6 and a half", "22 and a half"
            if c.allSatisfy(\.isNumber), !c.isEmpty {
                words.append(c)
                j += 1
                continue
            }
            if numberWords.contains(c) {
                words.append(c)
                j += 1
            } else {
                break
            }
        }
        guard !words.isEmpty else { return nil }

        // Next token after the number run (e.g. "items" in "ten items").
        let nextCore = j < parts.count ? normalizeToken(parts[j]) : ""
        let afterQuantity = !nextCore.isEmpty && quantityNouns.contains(nextCore)
        // Frequency: "three times a day" / "five times an hour" — not bare "three times".
        let afterFrequency = isFrequencyTimesAPeriod(parts: parts, afterNumber: j)
        // "two dozen" → 24 (multiplier, not "2 dozen")
        let afterDozen = nextCore == "dozen"
        // "two and a half dozen" → 30; "six and a half" → 6½
        let halfDozen = matchAndAHalf(parts: parts, start: j, requireDozen: true)
        let andAHalf = matchAndAHalf(parts: parts, start: j, requireDozen: false)
        let allowBare =
            forceConvert || afterQuantity || afterFrequency || afterDozen
            || halfDozen != nil || andAHalf != nil

        // Phone-style: consecutive single-digit units → concatenate
        // "five five five one two one two" → "5551212", "oh five five five" → "0555"
        // Short runs ("one two") stay conversational words unless min length lowered.
        if isDigitRun(words) {
            if let end = halfDozen, let n = digitRunInt(words) {
                let trailing = trailingPunctuation(parts[end - 1])
                return (formatValue(Double(n * 12 + 6)) + trailing, end)
            }
            if let end = andAHalf, let n = digitRunInt(words) {
                let trailing = trailingPunctuation(parts[end - 1])
                return (formatHalfMixed(n) + trailing, end)
            }
            if afterDozen, let n = digitRunInt(words) {
                let trailing = trailingPunctuation(parts[j])
                return (formatValue(Double(n * 12)) + trailing, j + 1)
            }
            if words.count >= digitRunMinLength, let digits = formatDigitRun(words) {
                let lastRaw = parts[j - 1]
                let trailing = trailingPunctuation(lastRaw)
                return (digits + trailing, j)
            }
            // Bare single digit before a quantity noun: "five emails" → "5 emails"
            if allowBare, words.count == 1, let digits = formatDigitRun(words) {
                let lastRaw = parts[j - 1]
                let trailing = trailingPunctuation(lastRaw)
                return (digits + trailing, j)
            }
            return nil
        } else if let value = parsePhrase(words), allowBare || shouldConvert(words) {
            if let end = halfDozen {
                let trailing = trailingPunctuation(parts[end - 1])
                let n = Int(value.rounded())
                return (formatValue(Double(n * 12 + 6)) + trailing, end)
            }
            if let end = andAHalf {
                let trailing = trailingPunctuation(parts[end - 1])
                let n = Int(value.rounded())
                return (formatHalfMixed(n) + trailing, end)
            }
            if afterDozen {
                let trailing = trailingPunctuation(parts[j])
                let n = Int(value.rounded())
                return (formatValue(Double(n * 12)) + trailing, j + 1)
            }
            let lastRaw = parts[j - 1]
            let trailing = trailingPunctuation(lastRaw)
            return (formatValue(value) + trailing, j)
        }
        // Bare unit + "and a half": "six and a half" (shouldConvert would refuse bare six)
        if let end = andAHalf, let n = integerFromWords(words) {
            let trailing = trailingPunctuation(parts[end - 1])
            return (formatHalfMixed(n) + trailing, end)
        }
        if let end = halfDozen, let n = integerFromWords(words) {
            let trailing = trailingPunctuation(parts[end - 1])
            return (formatValue(Double(n * 12 + 6)) + trailing, end)
        }
        return nil
    }

    /// Whole number + ½ as mixed unicode fraction string.
    private static func formatHalfMixed(_ whole: Int) -> String {
        if whole == 0 { return "½" }
        return "\(whole)½"
    }

    private static func integerFromWords(_ words: [String]) -> Int? {
        if words.count == 1, let n = Int(words[0]) { return n }
        if let n = digitRunInt(words) { return n }
        if let v = parsePhrase(words) { return Int(v.rounded()) }
        return nil
    }

    /// If parts[start…] is "and (a)? half [dozen]?", return index after last consumed token.
    /// `requireDozen`: true → must end with dozen; false → must NOT have dozen (bare half).
    private static func matchAndAHalf(
        parts: [String],
        start: Int,
        requireDozen: Bool
    ) -> Int? {
        guard start < parts.count, normalizeToken(parts[start]) == "and" else {
            return nil
        }
        var j = start + 1
        guard j < parts.count else { return nil }
        if normalizeToken(parts[j]) == "a" {
            j += 1
            guard j < parts.count else { return nil }
        }
        guard normalizeToken(parts[j]) == "half" else { return nil }
        j += 1
        if requireDozen {
            guard j < parts.count, normalizeToken(parts[j]) == "dozen" else { return nil }
            return j + 1
        }
        // Bare "and a half" — do not steal "... and a half dozen"
        if j < parts.count, normalizeToken(parts[j]) == "dozen" {
            return nil
        }
        return j
    }

    /// If parts[start…] is "and (a)? half dozen", return index after dozen.
    private static func matchAndAHalfDozen(parts: [String], start: Int) -> Int? {
        matchAndAHalf(parts: parts, start: start, requireDozen: true)
    }

    /// Whole-token mixed fractions from phraseFixes (½ … 5½) → integer whole part.
    private static func unicodeHalfValue(_ core: String) -> Int? {
        let map: [String: Int] = [
            "½": 0, "1½": 1, "2½": 2, "3½": 3, "4½": 4, "5½": 5,
        ]
        return map[core]
    }

    /// "(a )?couple of" / "(a )?pair of" → 2 (following noun kept by outer loop).
    private static func tryConsumeCoupleOrPairOf(
        parts: [String], start: Int
    ) -> (text: String, nextIndex: Int)? {
        var j = start
        guard j < parts.count else { return nil }
        if normalizeToken(parts[j]) == "a" {
            j += 1
            guard j < parts.count else { return nil }
        }
        let head = normalizeToken(parts[j])
        guard head == "couple" || head == "pair" else { return nil }
        j += 1
        guard j < parts.count, normalizeToken(parts[j]) == "of" else { return nil }
        // Consume through "of"; noun stays for outer apply loop.
        return ("2", j + 1)
    }

    /// Integer from a pure single-digit unit run (for dozen multiplier).
    private static func digitRunInt(_ words: [String]) -> Int? {
        guard isDigitRun(words) else { return nil }
        var n = 0
        for w in words {
            guard let u = units[w], u < 10 else { return nil }
            n = n * 10 + u
        }
        return n
    }

    /// "half a dozen" / "half dozen" → 6.
    private static func tryConsumeHalfDozen(
        parts: [String], start: Int
    ) -> (text: String, nextIndex: Int)? {
        guard start < parts.count, normalizeToken(parts[start]) == "half" else {
            return nil
        }
        var j = start + 1
        guard j < parts.count else { return nil }
        if normalizeToken(parts[j]) == "a" {
            j += 1
            guard j < parts.count else { return nil }
        }
        guard normalizeToken(parts[j]) == "dozen" else { return nil }
        let trailing = trailingPunctuation(parts[j])
        return ("6" + trailing, j + 1)
    }

    /// "a dozen" → 12 (not "the dozen" / "by the dozen").
    private static func tryConsumeADozen(
        parts: [String], start: Int
    ) -> (text: String, nextIndex: Int)? {
        guard start + 1 < parts.count,
              normalizeToken(parts[start]) == "a",
              normalizeToken(parts[start + 1]) == "dozen"
        else { return nil }
        let trailing = trailingPunctuation(parts[start + 1])
        return ("12" + trailing, start + 2)
    }

    /// True when tokens at `afterNumber` form `times a/an/per <period>` (e.g. "times a day").
    /// Does not match bare "times" or "times faster".
    private static func isFrequencyTimesAPeriod(parts: [String], afterNumber: Int) -> Bool {
        guard afterNumber + 2 < parts.count else { return false }
        let t0 = normalizeToken(parts[afterNumber])
        let t1 = normalizeToken(parts[afterNumber + 1])
        let t2 = normalizeToken(parts[afterNumber + 2])
        guard t0 == "times" else { return false }
        guard t1 == "a" || t1 == "an" || t1 == "per" else { return false }
        return frequencyPeriods.contains(t2)
    }

    /// "once a day" → ["1", "time", "a", "day"]; "twice per week" → ["2", "times", "per", "week"].
    /// Bare "once"/"twice" / "once more" / "twice as" stay unchanged.
    private static func tryConsumeOnceTwiceFrequency(
        parts: [String], start: Int
    ) -> (tokens: [String], nextIndex: Int)? {
        guard start + 2 < parts.count else { return nil }
        let core = normalizeToken(parts[start])
        guard core == "once" || core == "twice" else { return nil }
        let det = normalizeToken(parts[start + 1])
        let period = normalizeToken(parts[start + 2])
        guard det == "a" || det == "an" || det == "per" else { return nil }
        guard frequencyPeriods.contains(period) else { return nil }
        // Preserve trailing punct on period word if any
        let periodRaw = parts[start + 2]
        let periodOut = period + trailingPunctuation(periodRaw)
        if core == "once" {
            return (["1", "time", det, periodOut], start + 3)
        }
        return (["2", "times", det, periodOut], start + 3)
    }

    /// Parse a phrase of number words into a numeric value, or nil if invalid.
    static func parsePhrase(_ words: [String]) -> Double? {
        guard !words.isEmpty else { return nil }

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

    /// Format n as 1st / 2nd / 3rd / 4th …
    static func formatOrdinal(_ n: Int) -> String {
        let absN = abs(n)
        let mod100 = absN % 100
        let suffix: String
        if mod100 >= 11 && mod100 <= 13 {
            suffix = "th"
        } else {
            switch absN % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    // MARK: - Internals

    /// True when every word is a single digit unit (0–9), including "oh"/"zero".
    /// Used for phone-style digit runs; tens/teens/magnitudes/"and"/"point" fail.
    private static func isDigitRun(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        for w in words {
            guard let u = units[w], u < 10 else { return false }
        }
        return true
    }

    /// Concatenate single-digit units, preserving leading zeros ("oh" → 0).
    /// Phone-length runs (7 / 10 / 11-with-leading-1) get dashes.
    private static func formatDigitRun(_ words: [String]) -> String? {
        var digits = ""
        for w in words {
            guard let u = units[w], u < 10 else { return nil }
            digits.append(String(u))
        }
        guard !digits.isEmpty else { return nil }
        return formatPhoneDigits(digits)
    }

    /// Optional phone dashes: 7 → XXX-XXXX, 10 → XXX-XXX-XXXX, 11+leading 1 → 1-XXX-XXX-XXXX.
    /// Other lengths (years, short codes) stay plain digits.
    private static func formatPhoneDigits(_ digits: String) -> String {
        let chars = Array(digits)
        switch chars.count {
        case 7:
            return "\(String(chars[0..<3]))-\(String(chars[3..<7]))"
        case 10:
            return "\(String(chars[0..<3]))-\(String(chars[3..<6]))-\(String(chars[6..<10]))"
        case 11 where chars[0] == "1":
            return "1-\(String(chars[1..<4]))-\(String(chars[4..<7]))-\(String(chars[7..<11]))"
        default:
            return digits
        }
    }

    private static func shouldConvert(_ words: [String]) -> Bool {
        if words.count >= 2 { return true }
        guard let w = words.first else { return false }
        if tens[w] != nil { return true }
        if magnitudes[w] != nil { return true }
        if let u = units[w], u >= 13 { return true }
        return false
    }

    private static func shouldConvertOrdinal(value: Int, word: String, next: String) -> Bool {
        // Always convert multi-decade ordinals (twentieth) and teens ordinals
        if value >= 10 { return true }
        // first/second/third… blocked before discourse words
        if !next.isEmpty, ordinalBlockNext.contains(next) {
            return false
        }
        return true
    }

    private static func parseIntegerPhrase(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0
        var current = 0
        var sawNumber = false

        for w in words {
            if w == "and" {
                continue
            }
            if let u = units[w] {
                current += u
                sawNumber = true
            } else if let t = tens[w] {
                current += t
                sawNumber = true
            } else if let mag = magnitudes[w] {
                if current == 0 { current = 1 }
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
