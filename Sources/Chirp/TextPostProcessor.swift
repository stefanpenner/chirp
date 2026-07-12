// TextPostProcessor.swift — Light cleanup of raw transcription output.
// Removes filler words (um, uh, er…), deduplicates stuttered words,
// collapses whitespace, capitalizes standalone "I", applies high-confidence
// dictation phrase fixes, light inverse text normalization (times/%/$/units),
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
        // Pack spoken URL tokens before repetition collapse ("w w w"→"w",
        // "slash slash"→"slash") can destroy them.
        result = packSpokenURL(result)
        // Path prefixes before stutter collapse and generic slash phrase-fixes
        // so "tilde slash" → "~/" (not "tilde/" then bare tilde).
        result = packSpokenPath(result)
        result = removeFillersAndRepetitions(result)
        // Spoken single-letter runs → acronyms ("a p i" → "API") before phrase
        // fixes / ITN. Sticky spell + "spell as" re-split pure uppercase runs.
        result = SpellTransform.packAcronyms(result)
        result = applyPhraseFixes(result)
        result = applySpokenTerminalPunct(result)
        if FormatSettings.expandNumberedLists {
            result = SpokenListITN.apply(result, counter: &sessionListCounter)
        }
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

    /// Strip space before punct, but keep space before path prefixes "./" and "../".
    private static let spaceBeforePunctPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+([?!,;:]|\.(?!\.?/))"#)
    }()

    private static let multiSpacePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #" {2,}"#)
    }()

    /// "??" / ",," / ";;" → single mark (periods handled separately).
    private static let multiPunctPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"([?!,;:])\1+"#)
    }()

    /// ".." / "..." → "." but keep path parent prefix "../".
    private static let multiPeriodPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\.{2,}(?!/)"#)
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
            // www. before generic "dot com" so "www.example.com" glues.
            // Protocol (https://) is packed earlier in packSpokenURL.
            (#"\bwww\s+dot\b\s*"#, "www."),
            // Desktop dictation: spoken punctuation / structure (Mac Voice Control style)
            // Terminal punct (period / full stop / ? / !) is handled in
            // applySpokenTerminalPunct so mid-segment commands work too.
            // Allow segment start (`^`) so lone VAD chunks like "comma wait" rewrite.
            (#"(?:^|\s+)comma\b\s*"#, ", "),
            (#"(?:^|\s+)colon\b\s*"#, ": "),
            (#"(?:^|\s+)semicolon\b\s*"#, "; "),
            (#"(?:^|\s+)ellipsis\b"#, "…"),
            (#"(?:^|\s+)dot dot dot\b"#, "…"),
            (#"(?:^|\s+)em dash\b"#, "—"),
            (#"(?:^|\s+)en dash\b"#, "–"),
            (#"(?:^|\s+)dash\b"#, "—"),
            (#"(?:^|\s+)hyphen\b"#, "-"),
            // Double curly quotes (default "open/close quote")
            (#"(?:^|\s+)open quote\s*"#, "\u{201C}"),
            (#"(?:^|\s+)close quote\s*"#, "\u{201D}"),
            (#"(?:^|\s+)open double quote\s*"#, "\u{201C}"),
            (#"(?:^|\s+)close double quote\s*"#, "\u{201D}"),
            (#"(?:^|\s+)double quote\s*"#, "\u{201C}"),
            // Single / smart quotes
            (#"(?:^|\s+)open single quote\s*"#, "\u{2018}"),
            (#"(?:^|\s+)close single quote\s*"#, "\u{2019}"),
            (#"(?:^|\s+)single quote\s*"#, "\u{2018}"),
            (#"(?:^|\s+)apostrophe\s*"#, "\u{2019}"),
            (#"(?:^|\s+)open paren(?:thesis)?\s*"#, "("),
            (#"(?:^|\s+)close paren(?:thesis)?\s*"#, ")"),
            (#"(?:^|\s+)open bracket\s*"#, "["),
            (#"(?:^|\s+)close bracket\s*"#, "]"),
            (#"(?:^|\s+)open brace\s*"#, "{"),
            (#"(?:^|\s+)close brace\s*"#, "}"),
            (#"(?:^|\s+)open curly brace\s*"#, "{"),
            (#"(?:^|\s+)close curly brace\s*"#, "}"),
            (#"(?:^|\s+)dollar sign\b"#, "$"),
            // Social: glue tag/handle to the following word ("hashtag chirp" → "#chirp").
            // Capture form only — bare "hashtag" alone stays the word (low value as bare #).
            // Email uses bare "at" + host dots (applySpokenEmail first); never bare "at" here.
            (#"\bhashtag\s+(\w+)\b"#, "#$1"),
            (#"\bpound sign\s+(\w+)\b"#, "#$1"),
            (#"\b(?:at sign|at symbol)\s+(\w+)\b"#, "@$1"),
            (#"\bmention\s+(\w+)\b"#, "@$1"),
            (#"\s+ampersand\s*"#, " & "),
            (#"\s+percent sign\b"#, "%"),
            (#"(?:^|\s+)space bar\b"#, " "),
            (#"\s+new line\s*"#, "\n"),
            (#"\s+newline\s*"#, "\n"),
            (#"\s+line break\s*"#, "\n"),
            (#"\s+new paragraph\s*"#, "\n\n"),
            // Spoken symbols (Mac / Windows dictation style)
            // Absolute slash+segment runs packed in packSpokenPath (keeps space
            // before `/` after a word). Residual mid/end slash keeps space before `/`.
            (#"\s+(?:forward\s+)?slash\s+"#, " /"),
            (#"\s+(?:forward\s+)?slash$"#, " /"),
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
            (#"(?:^|\s+)tilde\b"#, "~"),
            (#"(?:^|\s+)caret\b"#, "^"),
            (#"\s+degree sign\b"#, "°"),
            // Degrees after numbers: handled in applyUnitsITN (after SpokenNumberITN)
            // so multi-word compounds ("seventy two degrees") become digits first.
            // Common fractions (unicode glyphs).
            // Do not rewrite after "and " — SpokenNumberITN owns mixed forms
            // ("ten and three quarters" → "10¾", not "ten and ¾").
            (#"(?<!and )\bone half\b"#, "½"),
            (#"(?<!and )\bone quarter\b"#, "¼"),
            (#"(?<!and )\bthree quarters\b"#, "¾"),
            // Mixed "N and a third/eighths" owned by SpokenNumberITN — bare only here.
            (#"(?<!and )\bone third\b"#, "⅓"),
            (#"(?<!and )\btwo thirds\b"#, "⅔"),
            (#"(?<!and )\bone fifth\b"#, "⅕"),
            (#"(?<!and )\btwo fifths\b"#, "⅖"),
            (#"(?<!and )\bthree fifths\b"#, "⅗"),
            (#"(?<!and )\bfour fifths\b"#, "⅘"),
            (#"(?<!and )\bone sixth\b"#, "⅙"),
            (#"(?<!and )\bfive sixths\b"#, "⅚"),
            (#"(?<!and )\bone eighth\b"#, "⅛"),
            (#"(?<!and )\bthree eighths\b"#, "⅜"),
            (#"(?<!and )\bfive eighths\b"#, "⅝"),
            (#"(?<!and )\bseven eighths\b"#, "⅞"),
            // Mixed numbers
            // Dozen compounds before bare "N and a half" (SpokenNumberITN owns general halves)
            (#"\bone and a half dozen\b"#, "18"),
            (#"\btwo and a half dozen\b"#, "30"),
            (#"\bthree and a half dozen\b"#, "42"),
            (#"\bfour and a half dozen\b"#, "54"),
            (#"\bfive and a half dozen\b"#, "60"),
            // Bare "N and a half" → SpokenNumberITN (general, not fixed 1–5 list)
            // Spoken web/domain fragments (email "local at host dots" handled in applySpokenEmail)
            (#"\s+dot com\b"#, ".com"),
            // ASR: "dat" ≈ "dot" for common TLDs (Parakeet dump)
            (#"\s+dat com\b"#, ".com"),
            (#"\s+dat org\b"#, ".org"),
            (#"\s+dat net\b"#, ".net"),
            (#"\s+dat io\b"#, ".io"),
            // "period com" only with known TLD (not mid-sentence content "period")
            (#"\s+period com\b"#, ".com"),
            (#"\s+period org\b"#, ".org"),
            (#"\s+period net\b"#, ".net"),
            (#"\s+period io\b"#, ".io"),
            // Bare space + long TLD (ASR drops "dot"): "example com" → "example.com"
            // Long TLDs only — never me/us/app/ai. Never glue after spoken connectors
            // (dot/dat/period) — those use the explicit "dot com" rules above.
            (#"\b(?!(?:dot|dat|period)\b)(\w{3,})\s+com\b"#, "$1.com"),
            (#"\b(?!(?:dot|dat|period)\b)(\w{3,})\s+org\b"#, "$1.org"),
            (#"\b(?!(?:dot|dat|period)\b)(\w{3,})\s+net\b"#, "$1.net"),
            (#"\b(?!(?:dot|dat|period)\b)(\w{3,})\s+edu\b"#, "$1.edu"),
            (#"\b(?!(?:dot|dat|period)\b)(\w{3,})\s+gov\b"#, "$1.gov"),
            // "www example com" → after host.tld glue: "www example.com" → "www.example.com"
            (#"\bwww\s+(\w{3,}\.(?:com|org|net|edu|gov))\b"#, "www.$1"),
            (#"\bwww\s+(\w{3,})\s+(com|org|net|edu|gov)\b"#, "www.$1.$2"),
            (#"\s+dot org\b"#, ".org"),
            (#"\s+dot net\b"#, ".net"),
            (#"\s+dot io\b"#, ".io"),
            (#"\s+dot edu\b"#, ".edu"),
            (#"\s+dot gov\b"#, ".gov"),
            // "dot co" with word boundary — must not match "dot company"
            (#"\s+dot co\b"#, ".co"),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    /// Spoken URL tokens that must pack before stutter collapse.
    /// (`"w w w"`→`"w"`, `"slash slash"`→`"slash"` would otherwise destroy them.)
    private static let spokenURLPackPatterns: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"\bdouble you double you double you\b"#, "www"),
            (#"\bw w w\b"#, "www"),
            (#"\bhttps\s+colon\s+(?:forward\s+)?slash\s+(?:forward\s+)?slash\b\s*"#, "https://"),
            (#"\bhttp\s+colon\s+(?:forward\s+)?slash\s+(?:forward\s+)?slash\b\s*"#, "http://"),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    private static func packSpokenURL(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in spokenURLPackPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    /// Spoken path prefixes before stutter collapse / generic slash phrase-fixes.
    /// `"tilde slash src"` → `"~/src"`, `"dot slash foo"` → `"./foo"`,
    /// `"dot dot slash src"` → `"../src"`, `"slash usr slash bin"` → `"/usr/bin"`.
    /// Only `dot slash` / `dot dot slash` (not `dot com`). Bare `tilde` → `~` last.
    /// Absolute `slash` runs are packed separately so "cd slash tmp" → "cd /tmp"
    /// (space before `/` when not at string start).
    private static let spokenPathPackPatterns: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            // Parent path before single "dot slash" (else "dot ./")
            (#"\bdot\s+dot\s+(?:forward\s+)?slash\b\s*"#, "../"),
            // Compound first so bare tilde does not fire on "tilde slash"
            (#"\btilde\s+(?:forward\s+)?slash\b\s*"#, "~/"),
            (#"\bhome\s+(?:forward\s+)?slash\b\s*"#, "~/"),
            // "dot slash" only — word boundary after slash keeps "dot com" alone
            (#"\bdot\s+(?:forward\s+)?slash\b\s*"#, "./"),
            // Bare tilde at start or after whitespace (path prefix)
            (#"(?:^|\s+)tilde\b"#, "~"),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    /// Absolute spoken path run: one or more `slash` + segment pairs.
    /// Group 1 = start anchor or leading whitespace; group 2 = spoken path body.
    private static let absoluteSpokenPathPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(^|\s+)((?:forward\s+)?slash\b\s+\S+(?:\s+(?:forward\s+)?slash\b\s+\S+)*)"#,
            options: .caseInsensitive
        )
    }()

    /// Strip spoken `slash` / `forward slash` tokens inside a path body → `/`.
    /// Optional leading whitespace so "usr slash bin" interiors pack as `/` not ` /`.
    private static let spokenSlashInPathPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\s*(?:forward\s+)?slash\b\s+"#,
            options: .caseInsensitive
        )
    }()

    private static func packSpokenPath(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in spokenPathPackPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        result = packAbsoluteSpokenPaths(result)
        return result
    }

    /// Pack absolute paths: `"slash usr"` → `"/usr"`, `"cd slash tmp"` → `"cd /tmp"`,
    /// `"slash usr slash bin"` → `"/usr/bin"`. Keeps one leading space when the
    /// match is not at string start (does not glue the previous word to `/`).
    private static func packAbsoluteSpokenPaths(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = absoluteSpokenPathPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let leadRange = Range(match.range(at: 1), in: result),
                  let bodyRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let lead = String(result[leadRange])
            let body = String(result[bodyRange])
            let bodyNS = body as NSString
            let packed = spokenSlashInPathPattern.stringByReplacingMatches(
                in: body,
                range: NSRange(location: 0, length: bodyNS.length),
                withTemplate: "/"
            )
            // At string start → no leading space; after a word → keep one space before `/`.
            let prefix = lead.isEmpty ? "" : " "
            result.replaceSubrange(fullRange, with: prefix + packed)
        }
        return result
    }

    /// Known TLDs for spoken "period <tld>" host connectors (ASR ≈ "dot").
    private static let spokenEmailTlds = "com|org|net|io|edu|gov|co|uk|us|me|app|dev|ai|info"

    /// "john at example dot com" / "john underscore smith at …" → email.
    /// Local connectors: dot|dat|underscore|under score|plus.
    /// Host: spoken dot/dat chains, "period <tld>", or space+TLD (ASR drops "dot").
    /// Optional "at the" (ASR often inserts the).
    /// "meet at noon" stays conversational (no known TLD token).
    private static let spokenEmailPattern: NSRegularExpression = {
        let tld = spokenEmailTlds
        // Host:
        //   (word (dot|dat) )+ word
        //   | word period <tld>
        //   | word+ <tld>  (ASR omitted "dot": "example com", "mail google com")
        let host =
            #"(?:(?:\w+\s+(?:dot|dat)\s+)+\w+|\w+\s+period\s+(?:"# + tld
            + #")|(?:\w+\s+)+(?:"# + tld + #"))"#
        let local =
            #"\w+(?:\s+(?:dot|dat|underscore|under\s+score|plus)\s+\w+)*"#
        let pattern =
            #"\b("# + local + #")\s+at(?:\s+the)?\s+("# + host + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
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
        "thanks for watching!", "thank you for watching!",
        "thanks for listening.", "thanks for listening",
        "subscribe.", "please subscribe.", "please subscribe",
        "please like and subscribe.", "please like and subscribe",
        "like and subscribe.", "like and subscribe",
        // Subtitle / media dumps common on silence (Whisper training leftovers)
        "subtitles by the amara.org community",
        "subtitles by the amara.org community.",
        "thanks for watching, and i'll see you next time.",
        "thanks for watching, and i'll see you next time",
        "thank you so much for joining us.",
        "thank you so much for joining us",
        "see you next time.", "see you next time",
        "the end.", "the end",
        "music", "[music]", "(music)",
        "applause", "[applause]", "laughter", "[laughter]",
        // Lone closings / greetings with punct (ASR silence dumps). Keep bare
        // "okay"/"hello"/"hi"/"yeah"/"yes" without punct — those can be real short speech.
        "bye.", "bye",
        "okay.", "ok.",
        "hello.", "hello?",
        "hi.", "hi?",
        "yeah.", "yeah?", "yes.", "yes?",
        "you.", "you?",
        "you know.", "i mean.",
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

    private static let bulletPatterns: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"(?:^|\s+)bullet point\s*"#, "\n• "),
            (#"(?:^|\s+)new bullet\s*"#, "\n• "),
            (#"(?:^|\s+)next bullet\s*"#, "\n• "),
            (#"(?:^|\s+)next item\s*"#, "\n• "),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()

    private static func applyPhraseFixes(_ text: String) -> String {
        var result = text
        // Email before bare "dot com" so multi-label hosts become @ not partial .com
        result = applySpokenEmail(result)
        for (pattern, replacement) in phraseFixes {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        // After TLD glue: ASR often yields "john at example.com" (live ITN dump).
        result = applyDottedHostEmail(result)
        if FormatSettings.expandBullets {
            for (pattern, replacement) in bulletPatterns {
                let range = NSRange(result.startIndex..., in: result)
                result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        return result
    }

    /// "local at label [dot label]+" → local@label.label… (multi-dot domains + co.uk).
    /// Local connectors: underscore→_, dot→., plus→+.
    private static func applySpokenEmail(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = spokenEmailPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let localRange = Range(match.range(at: 1), in: result),
                  let hostRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let localSpoken = String(result[localRange])
            let local = joinSpokenLocalPart(localSpoken)
            let hostSpoken = String(result[hostRange])
            // Spoken connectors → "."; bare space between labels → "." (missing-dot ASR)
            var host = hostSpoken.replacingOccurrences(
                of: #"\s+(?:dot|dat|period)\s+"#,
                with: ".",
                options: [.regularExpression, .caseInsensitive]
            )
            // Remaining spaces are label separators when last token is a TLD
            if host.contains(" ") {
                host = host.replacingOccurrences(
                    of: #"\s+"#,
                    with: ".",
                    options: .regularExpression
                )
            }
            result.replaceSubrange(fullRange, with: "\(local)@\(host)")
        }
        return result
    }

    /// Join spoken local-part tokens: "john underscore smith" → "john_smith".
    private static func joinSpokenLocalPart(_ spoken: String) -> String {
        var s = spoken
        let connectors: [(String, String)] = [
            (#"\s+under\s+score\s+"#, "_"),
            (#"\s+underscore\s+"#, "_"),
            (#"\s+(?:dot|dat)\s+"#, "."),
            (#"\s+plus\s+"#, "+"),
        ]
        for (pattern, replacement) in connectors {
            s = s.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return s
    }

    /// "local at host.tld" when host already has a literal domain (ASR / TLD glue).
    /// Does not steal "meet at noon" (no dotted host).
    private static let dottedHostEmailPattern: NSRegularExpression = {
        let tld = spokenEmailTlds
        // local may include _ . + from prior connector packing
        let pattern =
            #"\b([\w]+(?:[._+][\w]+)*)\s+at\s+([\w-]+(?:\.[\w-]+)*\.(?:"# + tld + #"))\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static func applyDottedHostEmail(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = dottedHostEmailPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let localRange = Range(match.range(at: 1), in: result),
                  let hostRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let local = String(result[localRange])
            let host = String(result[hostRange])
            result.replaceSubrange(fullRange, with: "\(local)@\(host)")
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

    // MARK: - Light ITN (times)

    /// Clock hour: spoken 1–12 or 1–2 digit numeral.
    private static let hourToken = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,2})"#

    /// Safe spoken minutes (00–59). Skips bare unit words ("three five pm" stays)
    /// to avoid ambiguity; uses oh/zero + unit, teens, tens, tens+unit.
    private static let spokenMinuteToken =
        #"(?:(?:oh|zero)\s+(?:zero|one|two|three|four|five|six|seven|eight|nine)|(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)|(?:twenty|thirty|forty|fifty)(?:\s+(?:one|two|three|four|five|six|seven|eight|nine))?)"#

    /// "three thirty pm" / "ten fifteen a.m." → hour:minutes + meridiem
    private static let timeWithMinutesPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\#(hourToken))\s+(\#(spokenMinuteToken)|\d{1,2})\s*([ap])\.?\s*m\.?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "three o'clock" / "three oclock pm" → 3:00 / 3:00 p.m.
    private static let oclockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\#(hourToken))\s+o'?clock(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "half past three" / "half past three pm" → 3:30 / 3:30 p.m.
    private static let halfPastPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bhalf\s+past\s+(\#(hourToken))(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "(a) quarter past three" → 3:15
    private static let quarterPastPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:a\s+)?quarter\s+past\s+(\#(hourToken))(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "(a) quarter to four" → 3:45 (hour wraps 1 → 12)
    private static let quarterToPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:a\s+)?quarter\s+to\s+(\#(hourToken))(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Spoken minutes used in "N past H" / "N to H" (safe set; not full 1–59).
    private static let clockMinutePhrase = #"(?:twenty[\s-]+five|twenty|fifteen|ten|five)"#

    /// "ten past three" / "twenty five past three pm" → 3:10 / 3:25 p.m.
    private static let minutesPastPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\#(clockMinutePhrase))\s+past\s+(\#(hourToken))(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "ten to three" / "five to one" → 2:50 / 12:55 (not cardinal "10-3").
    private static let minutesToPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\#(clockMinutePhrase))\s+to\s+(\#(hourToken))(?:\s*([ap])\.?\s*m\.?)?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Bare hour + am/pm: "three pm" → "3 p.m."
    private static let timeITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\#(hourToken))\s*([ap])\.?\s*m\.?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Dual-meridiem range: "nine am to five pm" → "9 a.m.-5 p.m."
    /// Optional minutes on either side; optional leading "from".
    private static let timeRangeDualMeridiemPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(from\s+)?(\#(hourToken))(?:\s+(\#(spokenMinuteToken)|\d{1,2}))?\s*([ap])\.?\s*m\.?\s+(?:to|through|until)\s+(\#(hourToken))(?:\s+(\#(spokenMinuteToken)|\d{1,2}))?\s*([ap])\.?\s*m\.?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Shared-meridiem range: "from three to five pm" → "from 3-5 p.m."
    /// Optional first-side minutes: "three thirty to five pm" → "3:30-5 p.m."
    /// Optional leading "from"; connector to|through|until; spoken or digit hours.
    private static let timeRangePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(from\s+)?(\#(hourToken))(?:\s+(\#(spokenMinuteToken)|\d{1,2}))?\s+(?:to|through|until)\s+(\#(hourToken))\s*([ap])\.?\s*m\.?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Digit or bare spoken unit/decade for cardinal ranges (after SpokenNumberITN
    /// most multi-word numbers are already digits; bare "ten" may remain).
    private static let cardinalRangeNumberToken =
        #"(\d{1,6}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

    /// "from 10 to 20" / "from ten to twenty" / "3 through 5" → "from 10-20" / "3-5".
    /// Negative lookahead: do not consume bounds that still have am/pm (time ranges
    /// should already have run; belt-and-suspenders).
    private static let cardinalRangePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(from\s+)?"# + cardinalRangeNumberToken
                + #"\s+(?:to|through|until)\s+"#
                + cardinalRangeNumberToken
                + #"\b(?!\s*[ap]\.?m\.?)"#,
            options: .caseInsensitive
        )
    }()

    /// "four out of five" / "4 out of 5" → "4/5". Optional "stars" not consumed.
    /// Requires numeric bounds on both sides so "out of order" stays prose.
    private static let ratingsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+out\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// Math / score ratios: "three over four", "22 divided by 7" → "3/4", "22/7".
    /// Both sides must be number tokens so "look over there" stays prose.
    private static let overRatioITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+over\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let dividedByRatioITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+divided\s+by\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "three plus four" → "3 + 4". Numeric bounds both sides.
    private static let plusMathITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+plus\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "ten minus three" → "10 - 3". Not bare "minus twenty" (no left number).
    private static let minusMathITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+minus\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "three times four" → "3 × 4". Negative lookahead: not "times a/an/per …"
    /// (frequency: "three times a day").
    private static let timesMathITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+times\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let multipliedByMathITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+multiplied\s+by\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let equalsMathITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+equals\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
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
        // Times before cardinals so "three thirty pm" is not eaten as 33.
        var result = applyTimeITN(text)
        // Dates before cardinals so "twenty twenty four" is not split into 20 24
        result = SpokenDateITN.apply(result)
        // Cardinals/ordinals (and remaining "march 15th" if date missed spoken day words)
        result = SpokenNumberITN.apply(result)
        // Second date pass: "march 15th" after ordinal ITN → "March 15"
        result = SpokenDateITN.apply(result)
        // Digit clock form after numbers: "3 30 pm" → "3:30 p.m."
        result = applyTimeITN(result)
        // Cardinal ranges after time ranges so "from 3 to 5 pm" is already
        // "from 3-5 p.m." and not stolen as "from 3-5" + leftover "pm".
        // "from ten to twenty" / "from 10 to 20" → "from 10-20".
        result = applyCardinalRangeITN(result)
        // Ratings after numbers: "four out of five" / "4 out of 5" → "4/5"
        // (optional "stars" left in place: "4/5 stars"). Not "out of order".
        result = applyRatingsITN(result)
        // Math ratios: "three over four" / "22 divided by 7" → "3/4" / "22/7".
        result = applyOverRatioITN(result)
        result = applyDividedByRatioITN(result)
        // Infix math: plus / minus / times / multiplied by / equals.
        // Times is N×M only (not "N times a day" — right side must be a number).
        result = applyMathOpsITN(result)
        // Powers after binary ops: "three squared" / "two to the power of three".
        result = applyPowerITN(result)
        // Roots / abs: "square root of nine" / "absolute value of five".
        result = applyRootAndAbsoluteITN(result)
        // Factorial / logs: "five factorial" / "log of ten" / "ln of five".
        result = applyFactorialAndLogITN(result)
        // Sterling/quid before units so "20 pounds sterling" → "£20" not "20 lb sterling".
        // Bare "pounds" stays weight via units; currency needs "sterling" or "quid".
        result = applySterlingCurrencyITN(result)
        // Units before simple currency so "5 pounds" → "5 lb" (weight) not "£5".
        // Spoken bare units ("ten feet") need number+unit here — SpokenNumberITN
        // leaves bare one…twelve alone ("one more thing").
        result = applyUnitsITN(result)
        // %/$ after numbers so "one hundred dollars" → "100 dollars" → "$100"
        result = applyPercentITN(result)
        result = applyCurrencyITN(result)
        // Street suffixes after numbers: "35 Lexington avenue" → "35 Lexington Ave."
        result = applyStreetSuffixITN(result)
        // Suite / room / floor / apt / unit / extension labels after numbers
        // ("suite 12" → "Suite 12", "floor 5" → "Floor 5", "extension 55" → "ext. 55").
        // Spoken digit runs (min 1) after these cues are forced in SpokenNumberITN.
        result = applySuiteRoomExtITN(result)
        // Version numbers: "version 2" / "version 1.5" → "v2" / "v1.5"
        // (spoken "version two" force-converted in SpokenNumberITN first).
        // Prose "the version is fine" has no digits after version → unchanged.
        result = applyVersionITN(result)
        // US states + ZIP after street suffixes so "… avenue california" → "… Ave. CA"
        // and "zip code 90210" → "90210". Multi-word states always rewrite; single-word
        // only with address cue left of match (street abbrev, ZIP, or "state of").
        result = applyAddressITN(result)
        // City title-case after street abbrev (once state is abbreviated).
        // "… Ave. boston MA" → "… Ave. Boston MA".
        result = applyCityTitleCaseAfterStreet(result)
        return result
    }

    /// Digit or spoken unit number (bare one…twelve + decades; compounds already digits).
    private static let unitsNumberToken =
        #"(\d+(?:\.\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

    /// Compact unit abbreviations only when preceded by a number.
    private static let unitsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + unitsNumberToken + #"\s+(miles?|kilometers?|kilometres?|feet|foot|inches|inch|pounds?|kilograms?)\b"#,
            options: .caseInsensitive
        )
    }()

    /// Height composite: "five foot ten" / "5 feet 10 inches" → 5'10"
    /// Requires both feet and inches numbers so bare "ten feet" stays for unit abbrev.
    /// Optional inches unit only consumes following space when present (keeps "  tall").
    private static let heightCompositePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + unitsNumberToken
                + #"\s+(?:foot|feet|ft)\s+"#
                + unitsNumberToken
                + #"(?:\s*(?:inches?|in))?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "N degrees" → "N°" (digits or bare spoken unit/decade; compounds already digits).
    private static let degreesITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + unitsNumberToken + #"\s+degrees?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Temperature scale: "72° fahrenheit" / "72 degrees fahrenheit" / "72 fahrenheit" → "72°F".
    private static let temperatureScalePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\d+(?:\.\d+)?)(?:°|°?\s*degrees?)?\s*(fahrenheit|celsius)\b"#,
            options: .caseInsensitive
        )
    }()

    private static func unitAbbreviation(for raw: String) -> String? {
        switch raw.lowercased() {
        case "mile", "miles": return "mi"
        case "kilometer", "kilometers", "kilometre", "kilometres": return "km"
        case "feet", "foot": return "ft"
        case "inch", "inches": return "in"
        case "pound", "pounds": return "lb"
        case "kilogram", "kilograms": return "kg"
        default: return nil
        }
    }

    private static func unitDigits(from raw: String) -> String {
        let key = raw.lowercased()
        return extendedSpokenNumbers[key] ?? raw
    }

    private static func applyUnitsITN(_ text: String) -> String {
        // Height before bare foot/feet/inch abbreviations.
        var result = applyHeightCompositeITN(text)
        result = applyUnitAbbreviations(result)
        // Degrees → ° then scale letter (after SpokenNumberITN in light pipeline).
        result = applyDegreesITN(result)
        result = applyTemperatureScale(result)
        return result
    }

    private static func applyHeightCompositeITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = heightCompositePattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let feetRange = Range(match.range(at: 1), in: result),
                  let inchRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let feet = unitDigits(from: String(result[feetRange]))
            let inches = unitDigits(from: String(result[inchRange]))
            result.replaceSubrange(fullRange, with: "\(feet)'\(inches)\"")
        }
        return result
    }

    private static func applyUnitAbbreviations(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = unitsITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let numRange = Range(match.range(at: 1), in: result),
                  let unitRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let num = unitDigits(from: String(result[numRange]))
            guard let abbr = unitAbbreviation(for: String(result[unitRange])) else { continue }
            result.replaceSubrange(fullRange, with: "\(num) \(abbr)")
        }
        return result
    }

    private static func applyDegreesITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = degreesITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let num = unitDigits(from: String(result[numRange]))
            result.replaceSubrange(fullRange, with: "\(num)°")
        }
        return result
    }

    private static func applyTemperatureScale(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = temperatureScalePattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let numRange = Range(match.range(at: 1), in: result),
                  let scaleRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let num = String(result[numRange])
            let scale = String(result[scaleRange]).lowercased()
            let letter: String
            switch scale {
            case "fahrenheit": letter = "F"
            case "celsius": letter = "C"
            default: continue
            }
            result.replaceSubrange(fullRange, with: "\(num)°\(letter)")
        }
        return result
    }

    /// Clock ITN: half/quarter, minutes+am/pm, o'clock, ranges, bare hour+am/pm.
    /// Half/quarter first so "half past three pm" is not eaten by bare "three pm".
    private static func applyTimeITN(_ text: String) -> String {
        var result = applyHalfQuarterITN(text)
        result = applyTimeWithMinutesITN(result)
        result = applyOClockITN(result)
        // Dual-meridiem ranges before shared-meridiem; both before bare hour
        // so "nine am to five pm" / "three to five pm" are not partially rewritten.
        result = applyTimeRangeDualMeridiemITN(result)
        result = applyTimeRangeITN(result)
        result = applyBareHourITN(result)
        return result
    }

    /// half past / quarter past / quarter to / N past / N to — British clock.
    private static func applyHalfQuarterITN(_ text: String) -> String {
        var result = applyClockPhrase(
            text, pattern: halfPastPattern, minutes: 30, hourDelta: 0,
            hourGroup: 1, meridiemGroup: 2
        )
        result = applyClockPhrase(
            result, pattern: quarterPastPattern, minutes: 15, hourDelta: 0,
            hourGroup: 1, meridiemGroup: 2
        )
        result = applyClockPhrase(
            result, pattern: quarterToPattern, minutes: 45, hourDelta: -1,
            hourGroup: 1, meridiemGroup: 2
        )
        // Variable minutes: "ten past three", "twenty five to five"
        result = applyMinutesPastToITN(result, pattern: minutesPastPattern, toForm: false)
        result = applyMinutesPastToITN(result, pattern: minutesToPattern, toForm: true)
        return result
    }

    /// "ten past three" / "ten to three" with spoken minute phrase in group 1.
    private static func applyMinutesPastToITN(
        _ text: String,
        pattern: NSRegularExpression,
        toForm: Bool
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let minRange = Range(match.range(at: 1), in: result),
                  let hourRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            guard let minVal = clockMinuteValue(String(result[minRange])) else { continue }
            // Only 1…12 face hours — avoid "ten to 20" as clock (cardinal range)
            guard let h = hourAsClockInt(String(result[hourRange])),
                  (1...12).contains(h) else { continue }
            let minutes: Int
            let hourDelta: Int
            if toForm {
                minutes = 60 - minVal
                hourDelta = -1
            } else {
                minutes = minVal
                hourDelta = 0
            }
            guard (0...59).contains(minutes) else { continue }
            var hour = h + hourDelta
            if hour < 1 { hour = 12 }
            let mins = String(format: "%02d", minutes)
            var out = "\(hour):\(mins)"
            if match.numberOfRanges >= 4,
               match.range(at: 3).location != NSNotFound,
               let apRange = Range(match.range(at: 3), in: result)
            {
                out += " \(formatMeridiem(result[apRange]))"
            }
            result.replaceSubrange(fullRange, with: out)
        }
        return result
    }

    private static func clockMinuteValue(_ raw: String) -> Int? {
        let key = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let map: [String: Int] = [
            "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "twenty five": 25,
        ]
        return map[key]
    }

    /// Shared rewriter for fixed-minute half/quarter: hourGroup + optional meridiem.
    private static func applyClockPhrase(
        _ text: String,
        pattern: NSRegularExpression,
        minutes: Int,
        hourDelta: Int,
        hourGroup: Int,
        meridiemGroup: Int
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges > hourGroup,
                  let hourRange = Range(match.range(at: hourGroup), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            guard let h = hourAsClockInt(String(result[hourRange])) else { continue }
            var hour = h + hourDelta
            if hourDelta != 0 {
                // Wrap 1…12 for spoken clock face; keep 13…23 linear for digit hours
                if (1...12).contains(h) {
                    if hour < 1 { hour = 12 }
                } else if hour < 0 {
                    hour = 23
                }
            }
            let hourStr = String(hour)
            let mins = String(format: "%02d", minutes)
            var out = "\(hourStr):\(mins)"
            if match.numberOfRanges > meridiemGroup,
               match.range(at: meridiemGroup).location != NSNotFound,
               let apRange = Range(match.range(at: meridiemGroup), in: result)
            {
                out += " \(formatMeridiem(result[apRange]))"
            }
            result.replaceSubrange(fullRange, with: out)
        }
        return result
    }

    /// Parse hour token to 1…12 (or 0…23 for digit input).
    private static func hourAsClockInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) {
            if (1...12).contains(n) { return n }
            if (13...23).contains(n) { return n } // keep 24h digit hours
            if n == 0 { return 12 }
            return nil
        }
        let map: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        ]
        return map[trimmed.lowercased()]
    }

    private static func formatHour(_ raw: String) -> String {
        let lower = raw.lowercased()
        return spokenNumbers[lower] ?? raw
    }

    private static func formatMeridiem(_ ap: Substring) -> String {
        "\(ap.lowercased()).m."
    }

    /// Parse spoken or digit minutes into 0…59, zero-padded "MM".
    private static func formatMinutes(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), (0...59).contains(n) {
            return String(format: "%02d", n)
        }
        let words = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let value = SpokenNumberITN.parsePhrase(words) else { return nil }
        let n = Int(value.rounded())
        guard (0...59).contains(n) else { return nil }
        return String(format: "%02d", n)
    }

    private static func applyTimeWithMinutesITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = timeWithMinutesPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let hourRange = Range(match.range(at: 1), in: result),
                  let minRange = Range(match.range(at: 2), in: result),
                  let apRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let hour = formatHour(String(result[hourRange]))
            guard let mins = formatMinutes(String(result[minRange])) else { continue }
            let mer = formatMeridiem(result[apRange])
            result.replaceSubrange(fullRange, with: "\(hour):\(mins) \(mer)")
        }
        return result
    }

    private static func applyOClockITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = oclockPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let hourRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let hour = formatHour(String(result[hourRange]))
            var out = "\(hour):00"
            if match.numberOfRanges >= 3,
               match.range(at: 2).location != NSNotFound,
               let apRange = Range(match.range(at: 2), in: result) {
                out += " \(formatMeridiem(result[apRange]))"
            }
            result.replaceSubrange(fullRange, with: out)
        }
        return result
    }

    /// Format optional clock minutes group; nil if absent or unparseable.
    private static func optionalMinutes(from match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        guard match.numberOfRanges > index,
              match.range(at: index).location != NSNotFound,
              let minRange = Range(match.range(at: index), in: text) else { return nil }
        return formatMinutes(String(text[minRange]))
    }

    private static func timeRangeFromPrefix(_ match: NSTextCheckingResult) -> String {
        match.range(at: 1).location != NSNotFound ? "from " : ""
    }

    private static func formatClockSide(hour: String, minutes: String?) -> String {
        if let minutes {
            return "\(hour):\(minutes)"
        }
        return hour
    }

    private static func applyTimeRangeDualMeridiemITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = timeRangeDualMeridiemPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            // Groups: 1=from, 2=h1, 3=m1?, 4=ap1, 5=h2, 6=m2?, 7=ap2
            guard match.numberOfRanges >= 8,
                  let hour1Range = Range(match.range(at: 2), in: result),
                  let ap1Range = Range(match.range(at: 4), in: result),
                  let hour2Range = Range(match.range(at: 5), in: result),
                  let ap2Range = Range(match.range(at: 7), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let fromPrefix = timeRangeFromPrefix(match)
            let h1 = formatHour(String(result[hour1Range]))
            let h2 = formatHour(String(result[hour2Range]))
            let m1 = optionalMinutes(from: match, at: 3, in: result)
            let m2 = optionalMinutes(from: match, at: 6, in: result)
            // If minutes group was present but unparseable, skip rewrite.
            if match.range(at: 3).location != NSNotFound && m1 == nil { continue }
            if match.range(at: 6).location != NSNotFound && m2 == nil { continue }
            let left = formatClockSide(hour: h1, minutes: m1)
            let right = formatClockSide(hour: h2, minutes: m2)
            let mer1 = formatMeridiem(result[ap1Range])
            let mer2 = formatMeridiem(result[ap2Range])
            result.replaceSubrange(
                fullRange,
                with: "\(fromPrefix)\(left) \(mer1)-\(right) \(mer2)"
            )
        }
        return result
    }

    private static func applyTimeRangeITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = timeRangePattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            // Groups: 1=from, 2=h1, 3=m1?, 4=h2, 5=ap
            guard match.numberOfRanges >= 6,
                  let hour1Range = Range(match.range(at: 2), in: result),
                  let hour2Range = Range(match.range(at: 4), in: result),
                  let apRange = Range(match.range(at: 5), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let fromPrefix = timeRangeFromPrefix(match)
            let h1 = formatHour(String(result[hour1Range]))
            let h2 = formatHour(String(result[hour2Range]))
            let m1 = optionalMinutes(from: match, at: 3, in: result)
            if match.range(at: 3).location != NSNotFound && m1 == nil { continue }
            let left = formatClockSide(hour: h1, minutes: m1)
            let mer = formatMeridiem(result[apRange])
            result.replaceSubrange(fullRange, with: "\(fromPrefix)\(left)-\(h2) \(mer)")
        }
        return result
    }

    private static func applyBareHourITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = timeITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let hourRange = Range(match.range(at: 1), in: result),
                  let apRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            // Skip already-normalized "3:30 p.m." — colon hour is not in hourToken digits-only
            // but "30 p.m." inside "3:30 p.m." must not rematch: word boundary after ':' is ok
            // for \d{1,2}. Guard: if char before match is ':', leave alone.
            if fullRange.lowerBound > result.startIndex {
                let prev = result[result.index(before: fullRange.lowerBound)]
                if prev == ":" { continue }
            }
            // Skip range tails already rewritten: "3-5 p.m." must not rematch "5 p.m."
            if fullRange.lowerBound > result.startIndex {
                let prev = result[result.index(before: fullRange.lowerBound)]
                if prev == "-" { continue }
            }
            let hour = formatHour(String(result[hourRange]))
            let mer = formatMeridiem(result[apRange])
            result.replaceSubrange(fullRange, with: "\(hour) \(mer)")
        }
        return result
    }

    /// "50 percent" / "fifty percent" / "100 percent" / "50 per cent" → "50%" / "100%".
    /// Uses shared cardinal token so multi-digit after SpokenNumberITN always hits.
    private static let percentITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+per\s*cents?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "three squared" / "4 cubed" — base is cardinal token (digits preferred post-ITN).
    private static let squaredITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken + #"\s+squared\b"#,
            options: .caseInsensitive
        )
    }()

    private static let cubedITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken + #"\s+cubed\b"#,
            options: .caseInsensitive
        )
    }()

    /// "two to the power of three" / "2 to the power of 10".
    private static let powerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+to\s+the\s+power\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "two to the third power" / "ten to the fourth power".
    private static let toTheNthPowerITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+to\s+the\s+"#
                + #"(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|"#
                + #"1st|2nd|3rd|4th|5th|6th|7th|8th|9th|10th|\d{1,2})"#
                + #"\s+power\b"#,
            options: .caseInsensitive
        )
    }()

    private static let ordinalPowerWords: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "sixth": 6, "6th": 6,
        "seventh": 7, "7th": 7, "eighth": 8, "8th": 8, "ninth": 9, "9th": 9,
        "tenth": 10, "10th": 10,
    ]

    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]

    private static let extendedSpokenNumbers: [String: String] = {
        var m = spokenNumbers
        m["thirteen"] = "13"; m["fourteen"] = "14"; m["fifteen"] = "15"
        m["sixteen"] = "16"; m["seventeen"] = "17"; m["eighteen"] = "18"
        m["nineteen"] = "19"
        m["twenty"] = "20"; m["thirty"] = "30"; m["forty"] = "40"
        m["fifty"] = "50"; m["sixty"] = "60"; m["seventy"] = "70"
        m["eighty"] = "80"; m["ninety"] = "90"
        return m
    }()

    /// Cardinal ranges without am/pm: "from ten to twenty" → "from 10-20".
    /// Time ranges with am/pm must run first and consume those matches.
    private static func applyCardinalRangeITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = cardinalRangePattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            // Groups: 1=from?, 2=left, 3=right
            guard match.numberOfRanges >= 4,
                  let leftRange = Range(match.range(at: 2), in: result),
                  let rightRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let fromPrefix = match.range(at: 1).location != NSNotFound ? "from " : ""
            let left = rangeDigits(from: String(result[leftRange]))
            let right = rangeDigits(from: String(result[rightRange]))
            result.replaceSubrange(fullRange, with: "\(fromPrefix)\(left)-\(right)")
        }
        return result
    }

    /// Ratings: "four out of five" / "4 out of 5" → "4/5". Keeps trailing "stars".
    private static func applyRatingsITN(_ text: String) -> String {
        applySlashRatioITN(text, pattern: ratingsITNPattern)
    }

    /// "three over four" / "22 over 100" → "3/4" / "22/100".
    private static func applyOverRatioITN(_ text: String) -> String {
        applySlashRatioITN(text, pattern: overRatioITNPattern)
    }

    /// "three divided by four" / "22 divided by 7" → "3/4" / "22/7".
    private static func applyDividedByRatioITN(_ text: String) -> String {
        applySlashRatioITN(text, pattern: dividedByRatioITNPattern)
    }

    /// Shared N ‹connector› M → N/M for ratings, over, divided-by.
    private static func applySlashRatioITN(_ text: String, pattern: NSRegularExpression) -> String {
        applyBinaryOpITN(text, pattern: pattern, joiner: "/")
    }

    /// plus / minus / times / multiplied by / equals → spaced operators.
    private static func applyMathOpsITN(_ text: String) -> String {
        var result = text
        result = applyBinaryOpITN(result, pattern: plusMathITNPattern, joiner: " + ")
        result = applyBinaryOpITN(result, pattern: minusMathITNPattern, joiner: " - ")
        result = applyBinaryOpITN(result, pattern: timesMathITNPattern, joiner: " × ")
        result = applyBinaryOpITN(result, pattern: multipliedByMathITNPattern, joiner: " × ")
        result = applyBinaryOpITN(result, pattern: equalsMathITNPattern, joiner: " = ")
        return result
    }

    /// Shared N ‹connector› M → left + joiner + right (digits preferred).
    private static func applyBinaryOpITN(
        _ text: String,
        pattern: NSRegularExpression,
        joiner: String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            // Groups: 1=N, 2=M
            guard match.numberOfRanges >= 3,
                  let leftRange = Range(match.range(at: 1), in: result),
                  let rightRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let left = rangeDigits(from: String(result[leftRange]))
            let right = rangeDigits(from: String(result[rightRange]))
            result.replaceSubrange(fullRange, with: "\(left)\(joiner)\(right)")
        }
        return result
    }

    private static func rangeDigits(from raw: String) -> String {
        let key = raw.lowercased()
        return extendedSpokenNumbers[key] ?? raw
    }

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

    /// Powers: squared / cubed / to the power of N / to the Nth power.
    private static func applyPowerITN(_ text: String) -> String {
        var result = text
        result = applyUnaryPowerITN(result, pattern: squaredITNPattern, exponent: 2)
        result = applyUnaryPowerITN(result, pattern: cubedITNPattern, exponent: 3)
        result = applyPowerOfITN(result)
        result = applyToTheNthPowerITN(result)
        return result
    }

    private static func applyUnaryPowerITN(
        _ text: String,
        pattern: NSRegularExpression,
        exponent: Int
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let baseRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let base = rangeDigits(from: String(result[baseRange]))
            result.replaceSubrange(fullRange, with: base + superscriptString(exponent))
        }
        return result
    }

    private static func applyPowerOfITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = powerOfITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let baseRange = Range(match.range(at: 1), in: result),
                  let expRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let base = rangeDigits(from: String(result[baseRange]))
            let expDigits = rangeDigits(from: String(result[expRange]))
            result.replaceSubrange(fullRange, with: base + superscriptFromDigits(expDigits))
        }
        return result
    }

    private static func applyToTheNthPowerITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = toTheNthPowerITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let baseRange = Range(match.range(at: 1), in: result),
                  let ordRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let base = rangeDigits(from: String(result[baseRange]))
            let ordRaw = String(result[ordRange]).lowercased()
            let exp: Int
            if let w = ordinalPowerWords[ordRaw] {
                exp = w
            } else if let n = Int(ordRaw.filter(\.isNumber)) {
                exp = n
            } else {
                continue
            }
            result.replaceSubrange(fullRange, with: base + superscriptString(exp))
        }
        return result
    }

    private static func superscriptString(_ n: Int) -> String {
        superscriptFromDigits(String(n))
    }

    private static func superscriptFromDigits(_ digits: String) -> String {
        var out = ""
        for ch in digits {
            if let s = superscriptDigits[ch] {
                out.append(s)
            } else if ch.isNumber {
                // Fallback caret form if unmapped
                return "^" + digits
            }
        }
        return out.isEmpty ? "^" + digits : out
    }

    /// "(the )?square root of N" / "cube root of N" / "absolute value of N".
    private static let squareRootITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?square\s+root\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let cubeRootITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?cube\s+root\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// Absolute value may wrap a signed digit form after SpokenNumberITN ("-20").
    private static let absoluteValueITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?absolute\s+value\s+of\s+(-?\d{1,9}|"#
                + #"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"#
                + #"thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|"#
                + #"twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applyRootAndAbsoluteITN(_ text: String) -> String {
        var result = text
        result = applyPrefixedNumberITN(
            result,
            pattern: squareRootITNPattern,
            wrap: { "√\($0)" }
        )
        result = applyPrefixedNumberITN(
            result,
            pattern: cubeRootITNPattern,
            wrap: { "∛\($0)" }
        )
        result = applyPrefixedNumberITN(
            result,
            pattern: absoluteValueITNPattern,
            wrap: { "|\($0)|" }
        )
        return result
    }

    /// Shared "… of N" → wrap(digits) for root / absolute.
    private static func applyPrefixedNumberITN(
        _ text: String,
        pattern: NSRegularExpression,
        wrap: (String) -> String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = rangeDigits(from: String(result[numRange]))
            result.replaceSubrange(fullRange, with: wrap(digits))
        }
        return result
    }

    /// "five factorial" → "5!"
    private static let factorialITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken + #"\s+factorial\b"#,
            options: .caseInsensitive
        )
    }()

    /// "log of ten" / "the logarithm of 10" → "log(10)"
    private static let logOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?log(?:arithm)?\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "natural log of five" / "ln of ten" → "ln(5)" / "ln(10)"
    private static let naturalLogOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:natural\s+log(?:arithm)?|ln)\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "log base two of eight" → "log₂(8)"
    private static let logBaseOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?log\s+base\s+"#
                + cardinalRangeNumberToken
                + #"\s+of\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applyFactorialAndLogITN(_ text: String) -> String {
        var result = text
        // Natural log / log base before bare "log of" so "natural log of" wins.
        result = applyPrefixedNumberITN(
            result,
            pattern: naturalLogOfITNPattern,
            wrap: { "ln(\($0))" }
        )
        result = applyLogBaseOfITN(result)
        result = applyPrefixedNumberITN(
            result,
            pattern: logOfITNPattern,
            wrap: { "log(\($0))" }
        )
        result = applyFactorialITN(result)
        return result
    }

    private static func applyFactorialITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = factorialITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = rangeDigits(from: String(result[numRange]))
            result.replaceSubrange(fullRange, with: "\(digits)!")
        }
        return result
    }

    private static func applyLogBaseOfITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = logBaseOfITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let baseRange = Range(match.range(at: 1), in: result),
                  let argRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let base = rangeDigits(from: String(result[baseRange]))
            let arg = rangeDigits(from: String(result[argRange]))
            let sub = subscriptFromDigits(base)
            result.replaceSubrange(fullRange, with: "log\(sub)(\(arg))")
        }
        return result
    }

    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    ]

    private static func subscriptFromDigits(_ digits: String) -> String {
        var out = ""
        for ch in digits {
            if let s = subscriptDigits[ch] {
                out.append(s)
            } else {
                return "_\(digits)"
            }
        }
        return out.isEmpty ? "_\(digits)" : out
    }

    /// Number token shared by currency patterns (digits preferred after SpokenNumberITN).
    private static let currencyNumberToken =
        #"(\d{1,9}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

    /// "20 dollars and 50 cents" → "$20.50" (apply before simple dollar/cent rules).
    /// "and" is optional: number ITN may consume "and fifty" → "50".
    private static let compoundDollarsCentsPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + currencyNumberToken + #"\s+dollars?\s+(?:and\s+)?"# + currencyNumberToken + #"\s+cents?\b"#,
            options: .caseInsensitive
        )
    }()

    /// "20 dollars|euros|yen" → currency symbol + digits.
    /// Bare pounds are weight (lb); use pounds sterling / quid via applySterlingCurrencyITN.
    private static let simpleCurrencyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + currencyNumberToken + #"\s+(dollars?|euros?|yen)\b"#,
            options: .caseInsensitive
        )
    }()

    /// "20 pounds sterling" / "20 pound sterling" / "20 quid" → "£20".
    private static let poundsSterlingPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + currencyNumberToken + #"\s+pounds?\s+sterling\b"#,
            options: .caseInsensitive
        )
    }()

    private static let quidPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + currencyNumberToken + #"\s+quid\b"#,
            options: .caseInsensitive
        )
    }()

    /// "50 cents" → "50¢" (standalone; compound handled above).
    private static let centsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + currencyNumberToken + #"\s+cents?\b"#,
            options: .caseInsensitive
        )
    }()

    /// USPS-style street suffixes only after a street number + name
    /// ("35 Lexington avenue" → "35 Lexington Ave."; not "hit the road").
    /// Name is 1–4 word tokens (Martin Luther King, North Main, …).
    private static let streetSuffixPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(\d{1,6})\s+((?:\w+\s+){0,3}\w+)\s+(street|avenue|road|drive|boulevard|lane|court|place|circle|highway)s?\b"#,
            options: .caseInsensitive
        )
    }()

    private static let streetSuffixAbbreviations: [String: String] = [
        "street": "St.", "streets": "St.",
        "avenue": "Ave.", "avenues": "Ave.",
        "road": "Rd.", "roads": "Rd.",
        "drive": "Dr.", "drives": "Dr.",
        "boulevard": "Blvd.", "boulevards": "Blvd.",
        "lane": "Ln.", "lanes": "Ln.",
        "court": "Ct.", "courts": "Ct.",
        "place": "Pl.", "places": "Pl.",
        "circle": "Cir.", "circles": "Cir.",
        "highway": "Hwy.", "highways": "Hwy.",
    ]

    private static func currencyDigits(from raw: String) -> String {
        let key = raw.lowercased()
        return extendedSpokenNumbers[key] ?? raw
    }

    /// Sterling disambiguators before units: "pounds sterling" / "quid" → £.
    private static func applySterlingCurrencyITN(_ text: String) -> String {
        var result = applyNumberCurrencySymbol(text, pattern: poundsSterlingPattern, symbol: "£")
        result = applyNumberCurrencySymbol(result, pattern: quidPattern, symbol: "£")
        return result
    }

    private static func applyNumberCurrencySymbol(
        _ text: String,
        pattern: NSRegularExpression,
        symbol: String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = currencyDigits(from: String(result[numRange]))
            result.replaceSubrange(fullRange, with: "\(symbol)\(digits)")
        }
        return result
    }

    private static func applyCurrencyITN(_ text: String) -> String {
        var result = applyCompoundDollarsCents(text)
        result = applySimpleCurrency(result)
        result = applyCentsITN(result)
        return result
    }

    private static func applyStreetSuffixITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = streetSuffixPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let numRange = Range(match.range(at: 1), in: result),
                  let nameRange = Range(match.range(at: 2), in: result),
                  let suffixRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let num = String(result[numRange])
            let name = titleCaseAddressWords(String(result[nameRange]))
            let rawSuffix = String(result[suffixRange]).lowercased()
            guard let abbr = streetSuffixAbbreviations[rawSuffix] else { continue }
            result.replaceSubrange(fullRange, with: "\(num) \(name) \(abbr)")
        }
        return result
    }

    /// Title-case address name tokens ("martin luther king" → "Martin Luther King").
    private static func titleCaseAddressWords(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: false).map { part in
            guard let first = part.first else { return String(part) }
            return String(first).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// After street abbrev, title-case 1–2 lowercase city tokens before state/ZIP/EOS.
    /// "… Ave. boston MA" → "… Ave. Boston MA". Not a full city gazetteer.
    private static let cityAfterStreetPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern:
                #"\b((?:St|Ave|Rd|Dr|Blvd|Ln|Ct|Pl|Cir|Hwy)\.)\s+([a-z]+(?:\s+[a-z]+)?)\b(?=\s+(?:[A-Z]{2}\b|\d{5})|\s*$)"#,
            options: []
        )
    }()

    private static func applyCityTitleCaseAfterStreet(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = cityAfterStreetPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let abbrRange = Range(match.range(at: 1), in: result),
                  let cityRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let abbr = String(result[abbrRange])
            let city = titleCaseAddressWords(String(result[cityRange]))
            result.replaceSubrange(fullRange, with: "\(abbr) \(city)")
        }
        return result
    }

    // MARK: - Suite / room / extension ITN

    /// "suite 12" / "room 101" / "floor 5" / "ext 55" / "apartment 4" after SpokenNumberITN.
    /// Digit-only body (spoken runs are forced to digits in SpokenNumberITN).
    /// End-of-phrase / address-adjacent only: do not rewrite "room 5 people".
    /// Lookahead: EOS + optional punct, comma, USPS state, or ZIP.
    private static let suiteRoomExtPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern:
                #"\b(suite|apartment|apt\.?|unit|room|floor|extension|ext\.?)\s+(\d{1,6})\b(?=\s*[.,;:!?]*\s*$|\s*,|\s+(?:A[KLRZ]|C[AOT]|D[CE]|FL|GA|HI|I[ADLN]|K[SY]|LA|M[ADEHINOST]|N[CDEHJMVY]|O[HKR]|P[AR]|RI|S[CD]|T[NX]|UT|V[AIT]|W[AIVY])\b|\s+\d{5}(?:-\d{4})?\b)"#,
            options: .caseInsensitive
        )
    }()

    // MARK: - Version ITN

    /// "version 2" / "version 1.5" → "v2" / "v1.5" after SpokenNumberITN.
    /// Cue word "version" only (bare "v two" avoided — false positives).
    private static let versionITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bversion\s+(\d+(?:\.\d+)?)\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applyVersionITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = versionITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = String(result[numRange])
            result.replaceSubrange(fullRange, with: "v\(digits)")
        }
        return result
    }

    /// Canonical labels: suite→Suite, apt→Apt., unit→Unit, room→Room, floor→Floor, ext→ext.
    private static func suiteRoomExtLabel(for raw: String) -> String? {
        let key = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        switch key {
        case "suite": return "Suite"
        case "apartment", "apt": return "Apt."
        case "unit": return "Unit"
        case "room": return "Room"
        case "floor": return "Floor"
        case "extension", "ext": return "ext."
        default: return nil
        }
    }

    private static func applySuiteRoomExtITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = suiteRoomExtPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let cueRange = Range(match.range(at: 1), in: result),
                  let numRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            guard let label = suiteRoomExtLabel(for: String(result[cueRange])) else { continue }
            let digits = String(result[numRange])
            result.replaceSubrange(fullRange, with: "\(label) \(digits)")
        }
        return result
    }

    // MARK: - Address ITN (US states + ZIP)

    /// Full US state / DC names → USPS 2-letter codes (keys lowercased).
    /// Multi-word names included; apply longest-first via pattern alternation order.
    private static let usStateAbbreviations: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
        "california": "CA", "colorado": "CO", "connecticut": "CT", "delaware": "DE",
        "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
        "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS",
        "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
        "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK",
        "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
        "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT",
        "vermont": "VT", "virginia": "VA", "washington": "WA", "west virginia": "WV",
        "wisconsin": "WI", "wyoming": "WY",
        "district of columbia": "DC",
    ]

    /// Whole-word state names, longest first so "new york" wins over nothing
    /// and "north carolina" is not partial-matched as shorter fragments.
    private static let stateITNPattern: NSRegularExpression = {
        let names = usStateAbbreviations.keys.sorted { $0.count > $1.count }
        let alt = names
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"\b("# + alt + #")\b"#,
            options: .caseInsensitive
        )
    }()

    /// "zip code 90210" / "zip codes 90210" / "zip 90210" (+ optional +4).
    private static let zipPrefixPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bzip(?:\s+codes?)?\s+(\d{5})(?:\s+(\d{4}))?\b"#,
            options: .caseInsensitive
        )
    }()

    /// Spaced ZIP+4: "90210 1234" → "90210-1234".
    private static let zipPlus4Pattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b(\d{5})\s+(\d{4})\b"#)
    }()

    /// States → USPS codes, then ZIP prefix strip / ZIP+4 hyphen.
    private static func applyAddressITN(_ text: String) -> String {
        var result = applyStateAbbreviationITN(text)
        result = applyZIPITN(result)
        return result
    }

    /// Street suffix abbreviations produced by street ITN (optional trailing period).
    private static let addressStreetAbbrevCuePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:St|Ave|Rd|Dr|Blvd|Ln|Ct|Pl|Cir|Hwy)\.?"#,
            options: .caseInsensitive
        )
    }()

    /// Bare 5-digit ZIP as an address cue for state rewrite.
    private static let addressZIPCuePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b\d{5}\b"#)
    }()

    /// Spoken "state of …" cue before a state name.
    private static let addressStateOfCuePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bstate\s+of\b"#,
            options: .caseInsensitive
        )
    }()

    /// True when left context looks like an address (street abbrev, ZIP, or "state of").
    private static func hasAddressCue(leftOf text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if addressStreetAbbrevCuePattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if addressZIPCuePattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if addressStateOfCuePattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        return false
    }

    /// Multi-word states always rewrite (low FP). Single-word only with address cue
    /// left of the match so "I love california" stays but "… Ave. california" → CA.
    private static func applyStateAbbreviationITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = stateITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let key = String(result[nameRange]).lowercased()
            guard let code = usStateAbbreviations[key] else { continue }
            let isMultiWord = key.contains(" ")
            if !isMultiWord {
                let left = String(result[..<fullRange.lowerBound])
                guard hasAddressCue(leftOf: left) else { continue }
            }
            result.replaceSubrange(fullRange, with: code)
        }
        return result
    }

    private static func applyZIPITN(_ text: String) -> String {
        var result = applyZIPPrefixStrip(text)
        result = applyZIPPlus4Hyphen(result)
        return result
    }

    private static func applyZIPPrefixStrip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = zipPrefixPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let zip5Range = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let zip5 = String(result[zip5Range])
            var out = zip5
            if match.numberOfRanges >= 3,
               match.range(at: 2).location != NSNotFound,
               let zip4Range = Range(match.range(at: 2), in: result) {
                out += "-\(result[zip4Range])"
            }
            result.replaceSubrange(fullRange, with: out)
        }
        return result
    }

    private static func applyZIPPlus4Hyphen(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = zipPlus4Pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let zip5Range = Range(match.range(at: 1), in: result),
                  let zip4Range = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let zip5 = String(result[zip5Range])
            let zip4 = String(result[zip4Range])
            result.replaceSubrange(fullRange, with: "\(zip5)-\(zip4)")
        }
        return result
    }

    private static func applyCompoundDollarsCents(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = compoundDollarsCentsPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let dollarsRange = Range(match.range(at: 1), in: result),
                  let centsRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let dollars = currencyDigits(from: String(result[dollarsRange]))
            var cents = currencyDigits(from: String(result[centsRange]))
            // Pad single-digit cents: "5 cents" → ".05"
            if cents.count == 1 { cents = "0" + cents }
            result.replaceSubrange(fullRange, with: "$\(dollars).\(cents)")
        }
        return result
    }

    private static func applySimpleCurrency(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = simpleCurrencyPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let numRange = Range(match.range(at: 1), in: result),
                  let unitRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = currencyDigits(from: String(result[numRange]))
            let unit = String(result[unitRange]).lowercased()
            let symbol: String
            switch unit {
            case "dollar", "dollars": symbol = "$"
            case "euro", "euros": symbol = "€"
            case "yen": symbol = "¥"
            default: continue
            }
            result.replaceSubrange(fullRange, with: "\(symbol)\(digits)")
        }
        return result
    }

    private static func applyCentsITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = centsITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let digits = currencyDigits(from: String(result[numRange]))
            result.replaceSubrange(fullRange, with: "\(digits)¢")
        }
        return result
    }

    private static func cleanWhitespace(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = spaceBeforePunctPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        // Periods separate so "../" path parent is preserved (not collapsed to "./").
        let range2 = NSRange(result.startIndex..., in: result)
        result = multiPeriodPattern.stringByReplacingMatches(in: result, range: range2, withTemplate: ".")
        let range3 = NSRange(result.startIndex..., in: result)
        result = multiPunctPattern.stringByReplacingMatches(in: result, range: range3, withTemplate: "$1")
        let range4 = NSRange(result.startIndex..., in: result)
        result = multiSpacePattern.stringByReplacingMatches(in: result, range: range4, withTemplate: " ")
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
