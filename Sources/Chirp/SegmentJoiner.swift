// SegmentJoiner.swift — Pure rules for joining VAD/ASR segments into one transcript.
// When VAD splits utterances on silence, the second often starts capitalized but
// the first may lack a terminal period ("Hello world" + "Create a note.").
// Insert ". " only when that pattern is clear; never invent punctuation mid-clause
// before proper nouns / product names (GitHub, Alice, VS Code).

import Foundation

enum SegmentJoiner {
    /// Join `next` onto `existing`. Returns the full text and the delta to type.
    /// - Parameter preserveLeadingCase: when true (spell mode), skip first-letter
    ///   truecase so packed letters keep explicit casing ("abc", "Ab").
    /// - Parameter emptySeparator: when true (spell mode or no-space mode glue),
    ///   join with no space so multi-segment packs become "abc" / "worldwide"
    ///   not "ab c" / "world wide".
    static func append(
        existing: String,
        next: String,
        preserveLeadingCase: Bool = false,
        emptySeparator: Bool = false
    ) -> (full: String, delta: String) {
        var piece = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else {
            return (existing, "")
        }
        if existing.isEmpty {
            // First segment of a session: capitalize leading letter if ASR left it lower.
            if !preserveLeadingCase {
                piece = capitalizeFirstLetter(piece)
            }
            return (piece, piece)
        }

        let separator = emptySeparator ? "" : separator(between: existing, and: piece)
        // After terminal punct / sentence break, next clause should start capitalized.
        // Mid-clause space joins: Parakeet often re-caps VAD segments — downcase
        // continuation verbs/function words so "I want to" + "Create" → "create".
        if !preserveLeadingCase {
            if let last = existing.last, ".!?…".contains(last) {
                piece = capitalizeFirstLetter(piece)
            } else if separator == ". " {
                piece = capitalizeFirstLetter(piece)
            } else if separator == " " || separator.isEmpty {
                piece = downcaseMidClauseContinuation(piece)
            }
        }
        let delta = separator + piece
        return (existing + delta, delta)
    }

    /// Separator between two non-empty segment strings.
    static func separator(between existing: String, and next: String) -> String {
        guard let last = existing.last else { return "" }

        // Already has terminal punctuation → single space
        if ".!?".contains(last) {
            return " "
        }
        // Trailing whitespace already present
        if last.isWhitespace {
            return needsSentenceBreak(existing: existing.trimmingCharacters(in: .whitespaces), next: next)
                ? ". "
                : ""
        }

        if needsSentenceBreak(existing: existing, next: next) {
            return ". "
        }
        return " "
    }

    /// True when `next` looks like a new sentence and `existing` does not end with punct.
    /// Dual-tested against specs/SegmentJoin.tla (`nextUpper ∧ ¬nextProper`).
    static func needsSentenceBreak(existing: String, next: String) -> Bool {
        guard let first = next.first else { return false }
        // New segment starts with uppercase letter → candidate new sentence
        guard first.isLetter, first.isUppercase else { return false }
        // Existing should end with a letter/digit (not already punct)
        guard let last = existing.last, last.isLetter || last.isNumber else { return false }
        // Suppress false periods before proper nouns / product names
        if looksLikeProperContinuation(next) {
            return false
        }
        return true
    }

    /// Proper-noun / product continuation after mid-clause text (space, not ". ").
    static func looksLikeProperContinuation(_ next: String) -> Bool {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'")) }
            .filter { !$0.isEmpty }
        guard let first = tokens.first else { return false }

        // Dict replacement values (GitHub, VS Code, …) including multi-word
        if isDictionaryValue(tokens: tokens) {
            return true
        }

        // Single Capitalized / CamelCase token — "Alice", "GitHub", "Xcode".
        // Mid-clause verbs/function words re-capped by ASR after a VAD pause
        // prefer space join (then downcased in append), not a false period.
        if tokens.count == 1 {
            if midClauseContinuations.contains(first.lowercased()) {
                return true
            }
            return isProperNameToken(first)
        }

        // Multi-word: continuation if first token is a mid-clause starter
        // ("Create a branch" after "I want to" → space, not ". ").
        // Discourse openers not in the set still get sentence breaks
        // ("Fortunately this works" after bare text).
        if midClauseContinuations.contains(first.lowercased()) {
            return true
        }
        return false
    }

    /// First words that usually continue a clause after a short VAD pause
    /// (ASR often re-capitalizes them). Prefer space join + downcase.
    private static let midClauseContinuations: Set<String> = [
        // Function words / articles / pronouns / auxiliaries
        "the", "a", "an", "my", "our", "your", "their", "his", "her", "its",
        "this", "that", "these", "those", "and", "or", "but", "so", "if",
        "when", "while", "because", "with", "without", "for", "to", "from",
        "into", "about", "after", "before", "as", "than", "then",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "would", "could", "should", "can", "may",
        "might", "must", "i", "we", "you", "they", "he", "she", "it",
        // Common imperative / coding verbs re-capped mid-dictation
        "create", "make", "add", "set", "get", "use", "open", "run", "write",
        "call", "put", "take", "send", "delete", "update", "build", "install",
        "deploy", "check", "look", "go", "come", "try", "start", "stop",
        "save", "load", "copy", "paste", "move", "fix", "change", "select",
        "insert", "remove", "type", "press", "click", "read", "find", "search",
        "review", "commit", "push", "pull", "merge", "test", "show", "hide",
        "close", "clear", "give", "keep", "let", "lets", "need", "want",
        "please", "just", "also", "only", "not", "no", "yes",
        "schedule", "book", "plan", "finish", "continue", "return",
    ]

    /// Downcase leading capital when the segment is a mid-clause continuation
    /// (not a proper name / dict product).
    static func downcaseMidClauseContinuation(_ text: String) -> String {
        guard let first = text.first, first.isLetter, first.isUppercase else { return text }
        let firstWord = String(text.prefix(while: { $0.isLetter }))
        guard midClauseContinuations.contains(firstWord.lowercased()) else { return text }
        // Keep CamelCase products (GitHub) — handled as proper, not mid-clause
        if firstWord.dropFirst().contains(where: \.isUppercase) { return text }
        return lowercaseFirstLetter(text)
    }

    static func lowercaseFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        guard first.isLetter, first.isUppercase else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func isDictionaryValue(tokens: [String]) -> Bool {
        let values = DictationDictionary.allEntries().values
        // Exact full-segment match (ignore trailing punct already stripped from tokens)
        let joined = tokens.joined(separator: " ")
        for value in values {
            if value.caseInsensitiveCompare(joined) == .orderedSame {
                return true
            }
            // Prefix match for "VS Code settings" / "GitHub access"
            let valueTokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !valueTokens.isEmpty, tokens.count >= valueTokens.count else { continue }
            var match = true
            for (i, vt) in valueTokens.enumerated() {
                if tokens[i].caseInsensitiveCompare(vt) != .orderedSame {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }

    /// Discourse / imperative words that start real new sentences even alone.
    private static let sentenceStarterWords: Set<String> = [
        "there", "this", "that", "these", "those", "then", "when", "what",
        "how", "why", "who", "where", "and", "but", "or", "so", "if",
        "yes", "no", "okay", "ok", "well", "also", "next", "finally",
        "first", "second", "last", "please", "create", "schedule", "send",
        "open", "delete", "clear", "make", "add", "remove", "write", "call",
        "set", "get", "put", "take", "give", "show", "hide", "close",
        "start", "stop", "thanks", "thank", "hello", "hi", "hey", "sure",
        "here", "now", "today", "tomorrow", "maybe", "perhaps", "actually",
        "however", "therefore", "anyway", "alright", "right", "let", "lets",
        "i", "we", "you", "they", "he", "she", "it", "my", "our", "your",
        "done", "ready", "wait", "stop", "go", "try", "use", "check",
        "review", "fix", "update", "install", "run", "build", "test",
        "commit", "push", "pull", "merge", "deploy",
    ]

    /// Single-token proper name / product (not a discourse sentence starter).
    private static func isProperNameToken(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter, first.isUppercase else { return false }
        if sentenceStarterWords.contains(token.lowercased()) {
            return false
        }
        let rest = token.dropFirst()
        // CamelCase / PascalCase product (GitHub, SwiftUI)
        if rest.contains(where: { $0.isUppercase }) {
            return true
        }
        // Title case name: Alice, Bob (rest lower or non-letters)
        return !rest.isEmpty && rest.allSatisfy { !$0.isLetter || $0.isLowercase }
    }

    /// Capitalize the first Unicode letter in `text` if it is lowercase.
    static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        guard first.isLetter, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
