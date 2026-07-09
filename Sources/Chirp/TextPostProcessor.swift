// TextPostProcessor.swift — Light cleanup of raw transcription output.
// Removes filler words (um, uh, er…), deduplicates stuttered words,
// collapses whitespace, capitalizes standalone "I", applies high-confidence
// dictation phrase fixes, and drops common silence-hallucination-only
// utterances.
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
        result = cleanWhitespace(result)
        result = capitalizeI(result)
        result = result.trimmingCharacters(in: .whitespaces)
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
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    /// Utterances Parakeet/Whisper-class models often emit from silence/noise alone.
    /// Only dropped when the *entire* cleaned segment matches — never mid-sentence.
    /// Keep this list tight: single-word dictation of "yes"/"okay"/"goodbye" is valid.
    private static let silenceHallucinations: Set<String> = [
        // Function words that almost never appear as intentional one-word dictation
        "you", "the", "a", "to", "and", "of", "in", "it", "is",
        // Classic Whisper/Parakeet silence artifacts (usually with trailing punct)
        "thank you.", "thanks.", "thank you for watching.",
        "subscribe.", "please subscribe.",
        // Pure vocalizations already partially handled as fillers; keep as whole-utterance drop
        "hmm", "hm", "mm", "mhm", "uh", "um", "ah", "er",
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
