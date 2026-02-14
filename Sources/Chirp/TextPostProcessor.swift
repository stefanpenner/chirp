// TextPostProcessor.swift — Light cleanup of raw transcription output.
// Removes filler words (um, uh, er…), deduplicates stuttered words,
// collapses whitespace, and capitalizes standalone "I".
// Pure String→String transform, no state, sub-millisecond.
// Applied by AppState at all three text insertion points.

import Foundation

enum TextPostProcessor {
    static func process(_ text: String) -> String {
        var result = text
        result = removeFillersAndRepetitions(result)
        result = cleanWhitespace(result)
        result = capitalizeI(result)
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Patterns (compiled once at static-init time)

    private static let fillerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:um|uh|uh huh|mm hmm|hmm|er|ah)\b[,.]?\s*"#,
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

    private static let lowercaseIPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?<=\s|^)i(?=\s|'|$)"#)
    }()

    // MARK: - Transforms

    private static func removeFillersAndRepetitions(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let range2 = NSRange(result.startIndex..., in: result)
        result = repetitionPattern.stringByReplacingMatches(in: result, range: range2, withTemplate: "$1")
        return result
    }

    private static func cleanWhitespace(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = spaceBeforePunctPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        let range2 = NSRange(result.startIndex..., in: result)
        result = multiSpacePattern.stringByReplacingMatches(in: result, range: range2, withTemplate: " ")
        return result
    }

    private static func capitalizeI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return lowercaseIPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
    }
}
