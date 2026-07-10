// TextPostProcessor.swift — Light cleanup of raw transcription output.
// Removes filler words (um, uh, er…), deduplicates stuttered words,
// collapses whitespace, capitalizes standalone "I", applies high-confidence
// dictation phrase fixes, light inverse text normalization (times/%/$),
// capitalizes after terminal punct / newlines, and drops silence hallucinations.
// Pure String→String transform, no state, sub-millisecond.
// Applied by AppState at all three text insertion points.
//
// Does NOT force whole-segment-start capitalization: process() runs per VAD
// segment, so capitalizing each chunk would mangle mid-sentence joins
// ("hello" + " world" → "Hello World"). Parakeet already emits casing.
// Mid-segment capitalize-after `.`/`?`/`!`/newline is safe and expected.

import Foundation

enum TextPostProcessor {
    /// Session list counter for "next number" across segments. Reset on new recording.
    /// `nonisolated(unsafe)` — single consumer thread / actor serializes access in practice.
    nonisolated(unsafe) static var sessionListCounter: Int = 1

    /// Call at the start of each hold-to-talk session (pipeline resetVAD).
    static func resetSessionFormatState() {
        sessionListCounter = 1
    }

    static func process(_ text: String) -> String {
        var result = text
        result = removeFillersAndRepetitions(result)
        result = applyPhraseFixes(result)
        result = applySpokenTerminalPunct(result)
        result = SpokenListITN.apply(result, counter: &sessionListCounter)
        result = DictationDictionary.apply(result)
        result = applyLightITN(result)
        result = cleanWhitespace(result)
        result = capitalizeI(result)
        result = capitalizeAfterTerminalPunct(result)
        // Trim spaces but keep leading/trailing newlines from spoken commands
        result = result.trimmingCharacters(in: CharacterSet.whitespaces)
        if isSilenceHallucination(result) {
            return ""
        }
        return result
    }

    // MARK: - Patterns (compiled once at static-init time)

    private static let fillerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            // Common spoken fillers. Avoid bare "like" / "so" — high false-positive rate.
            pattern: #"\b(?:um|uh|uh huh|mm hmm|mm-hmm|mmm|hmm|hm|er|ah|eh)\b[,.]?\s*"#,
            options: .caseInsensitive
        )
    }()

    private static let repetitionPattern: NSRegularExpression = {
        // "the the" → "the", "I I I" → "I"
        try! NSRegularExpression(
            pattern: #"\b(\w+)(?:\s+\1)+\b"#,
            options: .caseInsensitive
        )
    }()

    private static let spaceBeforePunctPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+([.?!,;:])"#)
    }()

    private static let multiSpacePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #" {2,}"#)
    }()

    private static let multiPunctPattern: NSRegularExpression = {
        // "??" / ".." / ",," → single mark
        try! NSRegularExpression(pattern: #"([.?!,;:])\1+"#)
    }()

    private static let lowercaseIPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?<=\s|^)i(?=\s|'|$)"#)
    }()

    /// High-confidence ASR confusions in dictation context only.
    /// Keep the list tiny — false fixes are worse than leaving ASR output.
    private static let phraseFixes: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            // "create a new node" is almost always "new note" in desktop dictation
            (#"\bnew node\b"#, "new note"),
            (#"\bnew nodes\b"#, "new notes"),
            // Common email/command confusions
            (#"\bsend (?:a )?mail\b"#, "send email"),
            (#"\bopen (?:the )?app store\b"#, "open the App Store"),
            // Desktop dictation: spoken punctuation / structure (Mac Voice Control style)
            // Terminal punct (period / full stop / ? / !) is handled in
            // applySpokenTerminalPunct so mid-segment commands work too.
            (#"\s+comma\b\s*"#, ", "),
            (#"\s+colon\b\s*"#, ": "),
            (#"\s+semicolon\b\s*"#, "; "),
            (#"\s+ellipsis\b"#, "…"),
            (#"\s+dot dot dot\b"#, "…"),
            (#"\s+em dash\b"#, "—"),
            (#"\s+en dash\b"#, "–"),
            (#"\s+dash\b"#, "—"),
            (#"\s+hyphen\b"#, "-"),
            (#"(?:^|\s+)open quote\s*"#, "\u{201C}"),
            (#"(?:^|\s+)close quote\s*"#, "\u{201D}"),
            (#"(?:^|\s+)open paren(?:thesis)?\s*"#, "("),
            (#"(?:^|\s+)close paren(?:thesis)?\s*"#, ")"),
            (#"(?:^|\s+)hashtag\s*"#, "#"),
            (#"(?:^|\s+)pound sign\s*"#, "#"),
            (#"\s+ampersand\s*"#, " & "),
            (#"\s+percent sign\b"#, "%"),
            (#"(?:^|\s+)space bar\b"#, " "),
            (#"\s+new line\s*"#, "\n"),
            (#"\s+newline\s*"#, "\n"),
            (#"\s+new paragraph\s*"#, "\n\n"),
            // Bulleted lists (Dragon-style multi-word only — avoid "bullet train")
            (#"(?:^|\s+)bullet point\s*"#, "\n• "),
            (#"(?:^|\s+)new bullet\s*"#, "\n• "),
            (#"(?:^|\s+)next bullet\s*"#, "\n• "),
            (#"(?:^|\s+)next item\s*"#, "\n• "),
            // Spoken symbols (Mac / Windows dictation style)
            (#"\s+(?:forward\s+)?slash\s+"#, "/"),
            (#"\s+(?:forward\s+)?slash$"#, "/"),
            (#"(?:^|\s+)backslash\s+"#, "\\"),
            (#"(?:^|\s+)back slash\s+"#, "\\"),
            (#"\s+asterisk\s+"#, "*"),
            (#"\s+asterisk$"#, "*"),
            (#"\s+underscore\s+"#, "_"),
            (#"\s+underscore$"#, "_"),
            (#"\s+plus sign\b"#, "+"),
            (#"\s+minus sign\b"#, "-"),
            (#"\s+equals sign\b"#, "="),
            (#"\s+equal sign\b"#, "="),
            (#"\s+greater than\b"#, ">"),
            (#"\s+less than\b"#, "<"),
            (#"\s+pipe\b"#, "|"),
            (#"\s+vertical bar\b"#, "|"),
            (#"\s+tilde\b"#, "~"),
            (#"\s+caret\b"#, "^"),
            (#"\s+degree sign\b"#, "°"),
            // "ninety degrees" after a number/word — require number word or digit before
            (#"\b(\d+|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|hundred)\s+degrees?\b"#, "$1°"),
            // Common fractions
            (#"\bone half\b"#, "½"),
            (#"\bone quarter\b"#, "¼"),
            (#"\bthree quarters\b"#, "¾"),
            (#"\bone third\b"#, "⅓"),
            (#"\btwo thirds\b"#, "⅔"),
            // Spoken web/domain fragments
            (#"\s+dot com\b"#, ".com"),
            (#"\s+dot org\b"#, ".org"),
            (#"\s+dot net\b"#, ".net"),
            (#"\s+dot io\b"#, ".io"),
            (#"\s+dot edu\b"#, ".edu"),
            (#"\s+dot gov\b"#, ".gov"),
            (#"\s+at sign\s*"#, "@"),
            (#"\s+at symbol\s*"#, "@"),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    /// Utterances Parakeet/Whisper-class models often emit from silence/noise alone.
    /// Only dropped when the *entire* cleaned segment matches — never mid-sentence.
    ///
    /// Do NOT list bare function words ("the", "a", "to"): a false VAD endpoint can
    /// legitimately decode only an onset word; dropping it loses real speech when
    /// pendingAudio was already committed. Keep multi-word / punctuated artifacts only.
    private static let silenceHallucinations: Set<String> = [
        // Classic Whisper/Parakeet silence artifacts
        "thank you.", "thanks.", "thank you for watching.",
        "thanks for watching.", "thank you for watching",
        "subscribe.", "please subscribe.", "please subscribe",
        // Pure vocalizations (also handled as fillers mid-sentence)
        "hmm", "hm", "mm", "mhm", "uh", "um", "ah", "er",
        "you", // common lone garbage token from noise; rarely intentional alone
    ]

    // MARK: - Transforms

    /// Number words that legitimately repeat in speech ("twenty twenty four" = 2024).
    private static let repetitionKeepWords: Set<String> = [
        "twenty", "thirty", "forty", "fourty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve",
    ]

    private static func removeFillersAndRepetitions(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // Collapse "the the" but keep "twenty twenty four" for year ITN
        let matches = repetitionPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let wordRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let word = String(result[wordRange]).lowercased()
            if repetitionKeepWords.contains(word) { continue }
            result.replaceSubrange(fullRange, with: result[wordRange])
        }
        return result
    }

    private static func applyPhraseFixes(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in phraseFixes {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    // MARK: - Mid-segment spoken terminal punctuation

    /// Safe multi-word terminal commands (almost never content words).
    private static let safeTerminalCommands: [(phrase: String, mid: String, end: String)] = [
        ("full stop", ". ", "."),
        ("question mark", "? ", "?"),
        ("exclamation mark", "! ", "!"),
        ("exclamation point", "! ", "!"),
    ]

    /// Words before "period" that mean the content noun, not a command.
    private static let periodContentPrev: Set<String> = [
        "the", "a", "an", "this", "that", "time", "grace", "trial", "waiting",
        "short", "long", "class", "first", "second", "third", "fourth",
        "cooling", "busy", "rest", "lunch", "peak", "open", "closed",
        "warranty", "notice", "transition", "probation",
    ]

    /// Words after "period" that mean the content noun, not a command.
    private static let periodContentNext: Set<String> = [
        "of", "is", "was", "were", "when", "between", "from", "in", "to",
        "for", "and", "or", "as", "end", "ends", "ended", "ending",
        "start", "starts", "started", "starting", "over", "under",
        "piece", "pieces", "drama", "table",
    ]

    /// Rewrite spoken terminal punct mid-segment and trailing.
    /// `"hello period next"` → `"hello. next"` (then capitalizeAfter → `"hello. Next"`).
    /// Keeps content collocations: `"the period is over"`.
    private static func applySpokenTerminalPunct(_ text: String) -> String {
        var result = text
        for cmd in safeTerminalCommands {
            result = replaceSpokenCommand(result, phrase: cmd.phrase, mid: cmd.mid, end: cmd.end)
        }
        result = replaceSpokenPeriod(result)
        return result
    }

    private static func replaceSpokenCommand(
        _ text: String,
        phrase: String,
        mid: String,
        end: String
    ) -> String {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            // Require a word boundary with space before (or start) — phrase already \b
            // Drop one leading whitespace so "hello full stop" → "hello."
            var replaceStart = matchRange.lowerBound
            if replaceStart > result.startIndex {
                let before = result.index(before: replaceStart)
                if result[before].isWhitespace {
                    replaceStart = before
                }
            }
            let after = matchRange.upperBound
            let trailing = result[after...].allSatisfy { $0.isWhitespace || $0.isNewline }
            let replacement = trailing ? end : mid
            // Consume one following space when mid so we don't double-space
            var replaceEnd = after
            if !trailing, replaceEnd < result.endIndex, result[replaceEnd].isWhitespace {
                replaceEnd = result.index(after: replaceEnd)
            }
            result.replaceSubrange(replaceStart..<replaceEnd, with: replacement)
        }
        return result
    }

    private static func replaceSpokenPeriod(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\bperiod\b"#,
            options: .caseInsensitive
        ) else { return text }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let prev = wordBefore(result, before: matchRange.lowerBound)?.lowercased()
            let next = wordAfter(result, after: matchRange.upperBound)?.lowercased()

            // Content collocations stay as the word "period"
            if let prev, periodContentPrev.contains(prev) { continue }
            if let next, periodContentNext.contains(next) { continue }

            var replaceStart = matchRange.lowerBound
            if replaceStart > result.startIndex {
                let before = result.index(before: replaceStart)
                if result[before].isWhitespace {
                    replaceStart = before
                }
            }
            let after = matchRange.upperBound
            let trailing = result[after...].allSatisfy { $0.isWhitespace || $0.isNewline }
            let replacement = trailing ? "." : ". "
            var replaceEnd = after
            if !trailing, replaceEnd < result.endIndex, result[replaceEnd].isWhitespace {
                replaceEnd = result.index(after: replaceEnd)
            }
            result.replaceSubrange(replaceStart..<replaceEnd, with: replacement)
        }
        return result
    }

    private static func wordBefore(_ text: String, before index: String.Index) -> String? {
        let prefix = text[text.startIndex..<index]
        let parts = prefix.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return parts.last.map(String.init)
    }

    private static func wordAfter(_ text: String, after index: String.Index) -> String? {
        let suffix = text[index...]
        let parts = suffix.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return parts.first.map(String.init)
    }

    /// Light inverse text normalization for dictation readability.
    /// Parakeet often already emits digits; this catches remaining spoken forms
    /// for clock times without a full ITN grammar.
    /// Ordinals like "first" are left alone — too many false positives
    /// ("first of all" must not become "1st of all").
    private static let timeITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,2})\s*([ap])\.?\s*m\.?\b"#,
            options: .caseInsensitive
        )
    }()

    private static let spokenNumbers: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12",
    ]

    /// Exposed for tests — light ITN pipeline only.
    static func applyLightITNForTesting(_ text: String) -> String {
        applyLightITN(text)
    }

    private static func applyLightITN(_ text: String) -> String {
        var result = applyTimeITN(text)
        // Dates before cardinals so "twenty twenty four" is not split into 20 24
        result = SpokenDateITN.apply(result)
        // Cardinals/ordinals (and remaining "march 15th" if date missed spoken day words)
        result = SpokenNumberITN.apply(result)
        // Second date pass: "march 15th" after ordinal ITN → "March 15"
        result = SpokenDateITN.apply(result)
        // %/$ after numbers so "one hundred dollars" → "100 dollars" → "$100"
        result = applyPercentITN(result)
        result = applyCurrencyITN(result)
        return result
    }

    private static func applyTimeITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = timeITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let hourRange = Range(match.range(at: 1), in: result),
                  let apRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let hourRaw = String(result[hourRange]).lowercased()
            let hour = spokenNumbers[hourRaw] ?? hourRaw
            let ap = result[apRange].lowercased()
            result.replaceSubrange(fullRange, with: "\(hour) \(ap).m.")
        }
        return result
    }

    /// "50 percent" / "fifty percent" / "100 percent" → "50%" / "100%".
    private static let percentITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\d{1,6}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\s+percent\b"#,
            options: .caseInsensitive
        )
    }()

    private static let extendedSpokenNumbers: [String: String] = {
        var m = spokenNumbers
        m["twenty"] = "20"; m["thirty"] = "30"; m["forty"] = "40"
        m["fifty"] = "50"; m["sixty"] = "60"; m["seventy"] = "70"
        m["eighty"] = "80"; m["ninety"] = "90"
        return m
    }()

    private static func applyPercentITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = percentITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let raw = String(result[numRange]).lowercased()
            let digits = extendedSpokenNumbers[raw] ?? raw
            result.replaceSubrange(fullRange, with: "\(digits)%")
        }
        return result
    }

    /// "20 dollars" / "twenty dollars" / "100 dollars" → "$20" / "$100".
    private static let currencyITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\d{1,9}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\s+dollars?\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applyCurrencyITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = currencyITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let raw = String(result[numRange]).lowercased()
            let digits = extendedSpokenNumbers[raw] ?? raw
            result.replaceSubrange(fullRange, with: "$\(digits)")
        }
        return result
    }

    private static func cleanWhitespace(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = spaceBeforePunctPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        let range2 = NSRange(result.startIndex..., in: result)
        result = multiPunctPattern.stringByReplacingMatches(in: result, range: range2, withTemplate: "$1")
        let range3 = NSRange(result.startIndex..., in: result)
        result = multiSpacePattern.stringByReplacingMatches(in: result, range: range3, withTemplate: " ")
        return result
    }

    private static func capitalizeI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return lowercaseIPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
    }

    /// Capitalize the first letter after terminal punctuation or a newline.
    /// Covers spoken-punctuation rewrites ("wait? next" → "wait? Next") and
    /// "new line" / "new paragraph" ("Hello\nworld" → "Hello\nWorld").
    ///
    /// Requires **whitespace after** `.`/`?`/`!`/`…` so we do not touch:
    /// - domains: `example.com`
    /// - times: `3 p.m.`
    /// - decimals: `3.14`
    /// Newlines may have zero spaces before the next letter.
    private static let afterTerminalPunctPattern: NSRegularExpression = {
        // Group 1 = letter to capitalize
        try! NSRegularExpression(pattern: #"(?:[.!?…]\s+|\n\s*)([a-z])"#)
    }()

    static func capitalizeAfterTerminalPunct(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = afterTerminalPunctPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let letterRange = Range(match.range(at: 1), in: result) else { continue }
            let letter = String(result[letterRange])
            result.replaceSubrange(letterRange, with: letter.uppercased())
        }
        return result
    }

    /// True when cleaned text is only a known silence-hallucination token.
    private static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return silenceHallucinations.contains(normalized)
    }
}
