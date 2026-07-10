// TextPostProcessor.swift — Light cleanup of raw transcription output.
// Removes filler words (um, uh, er…), deduplicates stuttered words,
// collapses whitespace, capitalizes standalone "I", applies high-confidence
// dictation phrase fixes, light inverse text normalization (times), and
// drops common silence-hallucination-only utterances.
// Pure String→String transform, no state, sub-millisecond.
// Applied by AppState at all three text insertion points.
//
// Does NOT force sentence-start capitalization: process() runs per VAD
// segment, so capitalizing each chunk would mangle mid-sentence joins
// ("hello" + " world" → "Hello World"). Parakeet already emits casing.

import Foundation

enum TextPostProcessor {
    static func process(_ text: String) -> String {
        var result = text
        result = removeFillersAndRepetitions(result)
        result = applyPhraseFixes(result)
        result = DictationDictionary.apply(result)
        result = applyLightITN(result)
        result = cleanWhitespace(result)
        result = capitalizeI(result)
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
            // Desktop dictation: spoken punctuation / structure commands
            (#"\s+period$"#, "."),
            (#"\s+comma\b\s*"#, ", "),
            (#"\s+question mark$"#, "?"),
            (#"\s+exclamation (?:mark|point)$"#, "!"),
            (#"\s+new line\s*"#, "\n"),
            (#"\s+newline\s*"#, "\n"),
            (#"\s+new paragraph\s*"#, "\n\n"),
            // Spoken web/domain fragments
            (#"\s+dot com\b"#, ".com"),
            (#"\s+dot org\b"#, ".org"),
            (#"\s+dot net\b"#, ".net"),
            (#"\s+dot io\b"#, ".io"),
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

    private static func removeFillersAndRepetitions(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let range2 = NSRange(result.startIndex..., in: result)
        result = repetitionPattern.stringByReplacingMatches(in: result, range: range2, withTemplate: "$1")
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

    private static func applyLightITN(_ text: String) -> String {
        applyTimeITN(text)
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

    /// True when cleaned text is only a known silence-hallucination token.
    private static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return silenceHallucinations.contains(normalized)
    }
}
