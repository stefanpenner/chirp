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
        // Letter accents before path tilde packing so "x tilde" → x̃ not "x~".
        result = applyLetterAccentITN(result)
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
            // Multi-word comparisons before bare greater/less than.
            (#"\bmuch\s+greater\s+than\b"#, "≫"),
            (#"\bmuch\s+less\s+than\b"#, "≪"),
            (#"\bless\s+than\s+or\s+equal(?:\s+to)?\b"#, "≤"),
            (#"\bgreater\s+than\s+or\s+equal(?:\s+to)?\b"#, "≥"),
            (#"\s+greater than\b"#, ">"),
            (#"\s+less than\b"#, "<"),
            (#"\s+pipe\b"#, "|"),
            (#"\s+vertical bar\b"#, "|"),
            // Bare ~ / ^ via "sign" cue — "x tilde" / "x hat" are letter accents in light ITN.
            (#"\b(?:tilde\s+sign|symbol\s+tilde)\b"#, "~"),
            (#"\b(?:caret\s+sign|symbol\s+caret)\b"#, "^"),
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
            // Bare tilde path prefix (after letter accents already rewrote "x tilde").
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
        #"(\d{1,6}|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

    /// Mantissa for scientific notation (allows decimals after SpokenNumberITN).
    private static let sciMantissaToken =
        #"(\d+\.\d+|\d{1,9}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

    /// Exponent: signed digits (after "minus three" → "-3") or bare spoken unit/decade.
    private static let signedExpToken =
        #"(-?\d{1,6}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"#

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
        // Tuples/ordered pairs before number ITN so "pair of" is not rewritten to 2.
        result = applyTupleOfITN(result)
        // Cardinals/ordinals (and remaining "march 15th" if date missed spoken day words)
        result = SpokenNumberITN.apply(result)
        // Second date pass: "march 15th" after ordinal ITN → "March 15"
        result = SpokenDateITN.apply(result)
        // Digit clock form after numbers: "3 30 pm" → "3:30 p.m."
        result = applyTimeITN(result)
        // Aggregate ranges before bare "from A to B" so "sum/product/integral
        // from 1 to 10" is not collapsed to "from 1-10" by cardinal-range ITN.
        result = applyAggregateFromToITN(result)
        // Limits: "limit as n approaches infinity" → lim(n→∞)
        result = applyLimitAsITN(result)
        // Calc ops: nabla, partial, gradient/divergence/curl, bare infinity
        result = applyCalcOperatorITN(result)
        // Letter accents before remaining bare-tilde/caret fallout; relations next.
        result = applyLetterAccentITN(result)
        result = applyMathRelationITN(result)
        // f of x → f(x); x sub i → xᵢ (after numbers so "h of zero" → h(0))
        result = applyFunctionOfITN(result)
        result = applySubscriptITN(result)
        // Cued Greek letters + "N pi" (after numbers so "two pi" → "2π")
        result = applyGreekLetterITN(result)
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
        // Scientific notation before bare "times" product: "3 times ten to the power of 5".
        result = applyScientificNotationITN(result)
        // E-notation "3 e 5" / "6 e minus 3" (numeric bounds both sides).
        result = applyENotationITN(result)
        // Infix math: plus / minus / times / multiplied by / equals.
        // Times is N×M only (not "N times a day" — right side must be a number).
        result = applyMathOpsITN(result)
        // Powers after binary ops: "three squared" / "two to the power of three".
        // Includes "e to the power of N" (Euler).
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

    /// "two to the power of three" / "2 to the power of -3" / "10 to the power of minus two".
    /// Exponent allows signed digits after SpokenNumberITN signed-minus conversion.
    private static let powerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + cardinalRangeNumberToken
                + #"\s+to\s+the\s+power\s+of\s+"#
                + signedExpToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "three times ten to the power of five" / "3.5 times 10 to the power of -2".
    private static let sciPowerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + sciMantissaToken
                + #"\s+times\s+(?:ten|10)\s+to\s+the\s+power\s+of\s+"#
                + signedExpToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "two times ten to the fourth power".
    private static let sciNthPowerITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + sciMantissaToken
                + #"\s+times\s+(?:ten|10)\s+to\s+the\s+"#
                + #"(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|"#
                + #"1st|2nd|3rd|4th|5th|6th|7th|8th|9th|10th|\d{1,2})"#
                + #"\s+power\b"#,
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
        if key == "zero" { return "0" }
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
        result = applyEPowerITN(result)
        result = applyPowerOfITN(result)
        result = applyToTheNthPowerITN(result)
        return result
    }

    /// Euler base powers: "e to the power of two" → "e²".
    private static func applyEPowerITN(_ text: String) -> String {
        var result = text
        // power of N
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = ePowerOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let expRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let expDigits = rangeDigits(from: String(result[expRange]))
                result.replaceSubrange(fullRange, with: "e" + superscriptFromDigits(expDigits))
            }
        }
        // to the Nth power
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = eNthPowerITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let ordRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let ordRaw = String(result[ordRange]).lowercased()
                let exp: Int
                if let w = ordinalPowerWords[ordRaw] {
                    exp = w
                } else if let n = Int(ordRaw.filter(\.isNumber)) {
                    exp = n
                } else {
                    continue
                }
                result.replaceSubrange(fullRange, with: "e" + superscriptString(exp))
            }
        }
        return result
    }

    /// Scientific notation before product "times": N×10ᴹ.
    private static func applyScientificNotationITN(_ text: String) -> String {
        var result = text
        result = applySciPowerOfITN(result)
        result = applySciNthPowerITN(result)
        return result
    }

    /// Calculator E-notation: "three e five" / "3.5 e -2" → "3e5" / "3.5e-2".
    /// Requires numeric mantissa and exponent so "the letter e" stays prose.
    private static let eNotationITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + sciMantissaToken
                + #"\s+e\s+"#
                + signedExpToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    /// "e to the power of two" / "e to the power of -1" (Euler base).
    private static let ePowerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\be\s+to\s+the\s+power\s+of\s+"#
                + signedExpToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let eNthPowerITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\be\s+to\s+the\s+"#
                + #"(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|"#
                + #"1st|2nd|3rd|4th|5th|6th|7th|8th|9th|10th|\d{1,2})"#
                + #"\s+power\b"#,
            options: .caseInsensitive
        )
    }()

    /// "sum/product/integral from A to B" → ∑/∏/∫(A…B).
    private static let aggregateFromToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(sum|product|integral)\s+from\s+"#
                + cardinalRangeNumberToken
                + #"\s+to\s+"#
                + cardinalRangeNumberToken
                + #"\b"#,
            options: .caseInsensitive
        )
    }()

    private static let aggregateFromToSymbols: [String: String] = [
        "sum": "∑",
        "product": "∏",
        "integral": "∫",
    ]

    private static func applyENotationITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = eNotationITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let mantRange = Range(match.range(at: 1), in: result),
                  let expRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let mant = rangeDigits(from: String(result[mantRange]))
            let exp = rangeDigits(from: String(result[expRange]))
            result.replaceSubrange(fullRange, with: "\(mant)e\(exp)")
        }
        return result
    }

    private static func applyAggregateFromToITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = aggregateFromToITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            // Groups: 1=kind, 2=lo, 3=hi (cardinal tokens each capture)
            guard match.numberOfRanges >= 4,
                  let kindRange = Range(match.range(at: 1), in: result),
                  let loRange = Range(match.range(at: 2), in: result),
                  let hiRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let kind = String(result[kindRange]).lowercased()
            guard let sym = aggregateFromToSymbols[kind] else { continue }
            let lo = rangeDigits(from: String(result[loRange]))
            let hi = rangeDigits(from: String(result[hiRange]))
            result.replaceSubrange(fullRange, with: "\(sym)(\(lo)…\(hi))")
        }
        return result
    }

    // MARK: - Greek letters + limits

    /// Spoken Greek names → lowercase / capital unicode (cued only, except Nπ).
    private static let greekLetterMap: [String: (lower: String, upper: String)] = [
        "alpha": ("α", "Α"), "beta": ("β", "Β"), "gamma": ("γ", "Γ"),
        "delta": ("δ", "Δ"), "epsilon": ("ε", "Ε"), "zeta": ("ζ", "Ζ"),
        "eta": ("η", "Η"), "theta": ("θ", "Θ"), "iota": ("ι", "Ι"),
        "kappa": ("κ", "Κ"), "lambda": ("λ", "Λ"), "mu": ("μ", "Μ"),
        "nu": ("ν", "Ν"), "xi": ("ξ", "Ξ"), "omicron": ("ο", "Ο"),
        "pi": ("π", "Π"), "rho": ("ρ", "Ρ"), "sigma": ("σ", "Σ"),
        "tau": ("τ", "Τ"), "upsilon": ("υ", "Υ"), "phi": ("φ", "Φ"),
        "chi": ("χ", "Χ"), "psi": ("ψ", "Ψ"), "omega": ("ω", "Ω"),
    ]

    /// "letter alpha" / "greek capital sigma" / "symbol pi"
    private static let cuedGreekITNPattern: NSRegularExpression = {
        let names = greekLetterMap.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern =
            #"\b(?:letter|greek|symbol)\s+(capital\s+)?("# + names + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "two pi" / "2 pi" / "3.14 pi" after SpokenNumberITN (not "pie").
    private static let nPiITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b"# + sciMantissaToken + #"\s+pi\b"#,
            options: .caseInsensitive
        )
    }()

    /// "limit as n approaches infinity" / "goes to" / "tends to"
    private static let limitAsITNPattern: NSRegularExpression = {
        let bound =
            #"infinity|\d{1,6}|zero|one|two|three|four|five|six|seven|eight|nine|ten|"#
            + #"eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|"#
            + #"twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"#
        let pattern =
            #"\b(?:the\s+)?limit\s+as\s+([A-Za-z])\s+"#
            + #"(?:approaches|goes\s+to|tends\s+to)\s+"#
            + #"("# + bound + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static func applyGreekLetterITN(_ text: String) -> String {
        var result = text
        // Cued forms first
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = cuedGreekITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let nameRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let capital = match.range(at: 1).location != NSNotFound
                let name = String(result[nameRange]).lowercased()
                guard let pair = greekLetterMap[name] else { continue }
                result.replaceSubrange(fullRange, with: capital ? pair.upper : pair.lower)
            }
        }
        // N π
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = nPiITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let nRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let n = rangeDigits(from: String(result[nRange]))
                result.replaceSubrange(fullRange, with: "\(n)π")
            }
        }
        return result
    }

    private static func applyLimitAsITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = limitAsITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let varRange = Range(match.range(at: 1), in: result),
                  let boundRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let v = String(result[varRange]).lowercased()
            let boundRaw = String(result[boundRange]).lowercased()
            let bound: String
            if boundRaw == "infinity" {
                bound = "∞"
            } else {
                bound = rangeDigits(from: boundRaw)
            }
            result.replaceSubrange(fullRange, with: "lim(\(v)→\(bound))")
        }
        return result
    }

    // MARK: - Calc operators (∇ ∂ ∞)

    /// "partial of f with respect to x" → ∂f/∂x
    private static let partialOfWRTITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bpartial(?:\s+derivative)?(?:\s+of)?\s+([A-Za-z])\s+with\s+respect\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "partial with respect to x" / "partial derivative with respect to t"
    private static let partialWRTITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bpartial(?:\s+derivative)?\s+with\s+respect\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "partial f" / "partial of f" — single-letter field only (not "partial payment")
    private static let partialOfVarITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bpartial(?:\s+of)?\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let gradientOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bgradient\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let divergenceOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bdivergence\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let curlOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bcurl\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let nablaITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:operator\s+)?nabla\b|\bdel\s+operator\b"#,
            options: .caseInsensitive
        )
    }()

    private static let infinityITNPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\binfinity\b"#, options: .caseInsensitive)
    }()

    private static func applyCalcOperatorITN(_ text: String) -> String {
        var result = text
        // Longest partial forms first
        result = applyTwoLetterOpITN(
            result,
            pattern: partialOfWRTITNPattern,
            wrap: { f, x in "∂\(f)/∂\(x)" }
        )
        result = applyOneLetterOpITN(
            result,
            pattern: partialWRTITNPattern,
            wrap: { x in "∂/∂\(x)" }
        )
        result = applyOneLetterOpITN(
            result,
            pattern: partialOfVarITNPattern,
            wrap: { f in "∂\(f)" }
        )
        result = applyOneLetterOpITN(
            result,
            pattern: gradientOfITNPattern,
            wrap: { f in "∇\(f)" }
        )
        result = applyOneLetterOpITN(
            result,
            pattern: divergenceOfITNPattern,
            wrap: { f in "∇·\(f)" }
        )
        result = applyOneLetterOpITN(
            result,
            pattern: curlOfITNPattern,
            wrap: { f in "∇×\(f)" }
        )
        // nabla / del operator
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = nablaITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result) else { continue }
                result.replaceSubrange(full, with: "∇")
            }
        }
        // bare infinity (after limit ITN already consumed "approaches infinity" in lim forms)
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = infinityITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result) else { continue }
                result.replaceSubrange(full, with: "∞")
            }
        }
        return result
    }

    private static func applyOneLetterOpITN(
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
                  let letterRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let letter = String(result[letterRange])
            result.replaceSubrange(fullRange, with: wrap(letter))
        }
        return result
    }

    private static func applyTwoLetterOpITN(
        _ text: String,
        pattern: NSRegularExpression,
        wrap: (String, String) -> String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let aRange = Range(match.range(at: 1), in: result),
                  let bRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let a = String(result[aRange])
            let b = String(result[bRange])
            result.replaceSubrange(fullRange, with: wrap(a, b))
        }
        return result
    }

    // MARK: - Math relations + letter accents

    /// Phrase → symbol. Multi-word only (safe in free dictation).
    private static let mathRelationPhrases: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"\bnot\s+equal(?:s)?\s+to\b"#, "≠"),
            (#"\bdoes\s+not\s+equal\b"#, "≠"),
            (#"\bapproximately\s+equal(?:\s+to)?\b"#, "≈"),
            (#"\bapprox(?:imate(?:ly)?)?\s+equal(?:\s+to)?\b"#, "≈"),
            (#"\bless\s+than\s+or\s+equal(?:\s+to)?\b"#, "≤"),
            (#"\bgreater\s+than\s+or\s+equal(?:\s+to)?\b"#, "≥"),
            (#"\bmuch\s+greater\s+than\b"#, "≫"),
            (#"\bmuch\s+less\s+than\b"#, "≪"),
            (#"\bproportional\s+to\b"#, "∝"),
            (#"\bnot\s+element\s+of\b"#, "∉"),
            (#"\belement\s+of\b"#, "∈"),
            (#"\bmember\s+of\b"#, "∈"),
            (#"\bif\s+and\s+only\s+if\b"#, "⇔"),
            (#"\bdouble\s+right\s+arrow\b"#, "⇒"),
            (#"\bright\s+double\s+arrow\b"#, "⇒"),
            (#"\bleft\s+right\s+double\s+arrow\b"#, "⇔"),
            // Cued logic words (bare "therefore"/"because" stay prose)
            (#"\b(?:symbol\s+therefore|therefore\s+sign)\b"#, "∴"),
            (#"\b(?:symbol\s+because|because\s+sign)\b"#, "∵"),
            (#"\bsymbol\s+for\s+all\b"#, "∀"),
            (#"\bsymbol\s+there\s+exists\b"#, "∃"),
            (#"\bfor\s+all\s+symbol\b"#, "∀"),
            (#"\bthere\s+exists\s+symbol\b"#, "∃"),
        ]
        return pairs.map { pat, rep in
            (try! NSRegularExpression(pattern: pat, options: .caseInsensitive), rep)
        }
    }()

    private static func applyMathRelationITN(_ text: String) -> String {
        var result = text
        for (re, rep) in mathRelationPhrases {
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rep
            )
        }
        return result
    }

    /// Combining accents (Unicode): hat U+0302, bar U+0304, tilde U+0303, vector U+20D7.
    private static let combiningHat = "\u{0302}"
    private static let combiningBar = "\u{0304}"
    private static let combiningTilde = "\u{0303}"
    private static let combiningVector = "\u{20D7}"
    /// Prime marks (not combining): ′ ″ ‴
    private static let primeMark = "\u{2032}"
    private static let doublePrimeMark = "\u{2033}"
    private static let triplePrimeMark = "\u{2034}"

    private static let letterAccentSpecs: [(pattern: NSRegularExpression, mark: String)] = {
        // Longer prime phrases first so "double prime" is not "prime" after "double ".
        let specs: [(String, String)] = [
            (#"\b([A-Za-z])\s+triple\s+prime\b"#, triplePrimeMark),
            (#"\btriple\s+prime\s+([A-Za-z])\b"#, triplePrimeMark),
            (#"\b([A-Za-z])\s+double\s+prime\b"#, doublePrimeMark),
            (#"\bdouble\s+prime\s+([A-Za-z])\b"#, doublePrimeMark),
            (#"\b([A-Za-z])\s+prime\b"#, primeMark),
            (#"\bprime\s+([A-Za-z])\b"#, primeMark),
            (#"\b([A-Za-z])\s+hat\b"#, combiningHat),
            (#"\bhat\s+([A-Za-z])\b"#, combiningHat),
            (#"\b([A-Za-z])\s+bar\b"#, combiningBar),
            (#"\bbar\s+([A-Za-z])\b"#, combiningBar),
            (#"\b([A-Za-z])\s+tilde\b"#, combiningTilde),
            (#"\btilde\s+([A-Za-z])\b"#, combiningTilde),
            (#"\b([A-Za-z])\s+vector\b"#, combiningVector),
            (#"\bvector\s+([A-Za-z])\b"#, combiningVector),
        ]
        return specs.map { pat, mark in
            (try! NSRegularExpression(pattern: pat, options: .caseInsensitive), mark)
        }
    }()

    private static func applyLetterAccentITN(_ text: String) -> String {
        var result = text
        for (re, mark) in letterAccentSpecs {
            let range = NSRange(result.startIndex..., in: result)
            let matches = re.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let letterRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let letter = String(result[letterRange])
                result.replaceSubrange(fullRange, with: letter + mark)
            }
        }
        return result
    }

    // MARK: - Function application + subscripts

    /// Named math functions allowed before "of" (not prose verbs).
    private static let mathFunctionNames =
        "sin|cos|tan|sec|csc|cot|arcsin|arccos|arctan|sinh|cosh|tanh|exp|det|max|min|gcd|lcm|erf|abs"

    /// Arg token shared by single- and multi-arg function "of" forms.
    private static let functionArgToken =
        #"[A-Za-z]|\d{1,6}|zero|one|two|three|four|five|six|seven|eight|nine|ten"#

    private static let functionNameToken =
        #"(?:[fghFGH])|(?:"# + mathFunctionNames + #")"#

    /// "f of x and y and z" — three args (apply before two-arg).
    private static let functionOfThreeITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b("# + functionNameToken + #")\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "f of x and y" / "max of m and n" — two args (apply before single-arg).
    private static let functionOfTwoITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b("# + functionNameToken + #")\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "f of x comma y" / "f of x, y, z" after spoken-comma rewrite.
    private static let functionOfCommaITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b("# + functionNameToken + #")\s+of\s+("#
            + a + #")\s*,\s*("# + a + #")(?:\s*,\s*("# + a + #"))?\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Single-letter or named: "f of x" / "sin of x" / "h of 0"
    private static let functionOfITNPattern: NSRegularExpression = {
        let pattern =
            #"\b("# + functionNameToken + #")\s+of\s+("#
            + functionArgToken + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "tuple of x and y" / "ordered pair of a and b" / three-arg tuple.
    private static let tupleOfThreeITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b(?:the\s+)?(?:tuple|ordered\s+pair)\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let tupleOfTwoITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b(?:the\s+)?(?:tuple|ordered\s+pair)\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "set of a and b [and c]"
    private static let setOfThreeITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b(?:the\s+)?set\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let setOfTwoITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b(?:the\s+)?set\s+of\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "set of a comma b comma c" after spoken comma → ","
    private static let setOfCommaITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\b(?:the\s+)?set\s+of\s+("#
            + a + #")\s*,\s*("# + a + #")(?:\s*,\s*("# + a + #"))?\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "row of 1 and 2 and 3" → [1, 2, 3]
    private static let rowOfThreeITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\brow\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let rowOfTwoITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\brow\s+of\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "column of a and b [and c]" / "column vector of …" → [[a], [b], …]
    private static let columnOfThreeITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\bcolumn(?:\s+vector)?\s+of\s+("#
            + a + #")\s+and\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let columnOfTwoITNPattern: NSRegularExpression = {
        let a = functionArgToken
        let pattern =
            #"\bcolumn(?:\s+vector)?\s+of\s+("# + a + #")\s+and\s+("# + a + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "empty set" → ∅
    private static let emptySetITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?empty\s+set\b"#,
            options: .caseInsensitive
        )
    }()

    /// Interval bounds (same as function args / small numbers).
    private static let intervalBoundToken = functionArgToken

    /// "closed/open/left closed/right closed interval from A to B"
    private static let intervalFromToITNPattern: NSRegularExpression = {
        let b = intervalBoundToken
        let pattern =
            #"\b(closed|open|half\s+open|left\s+closed|right\s+closed)\s+interval\s+from\s+("#
            + b + #")\s+to\s+("# + b + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()



    /// Index token for sub/super: letter, digit run, or small spoken number.
    private static let indexToken =
        #"[A-Za-z]|\d{1,3}|zero|one|two|three|four|five|six|seven|eight|nine|ten"#

    /// "x sub i" / "a subscript 0" / "v sub n"
    private static let subscriptITNPattern: NSRegularExpression = {
        let pattern =
            #"\b([A-Za-z])\s+(?:sub(?:script)?)\s+("# + indexToken + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "x super n" / "a superscript 2" — free index / power without "to the power of".
    private static let superscriptITNPattern: NSRegularExpression = {
        let pattern =
            #"\b([A-Za-z])\s+(?:super(?:script)?)\s+("# + indexToken + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let subscriptLetterMap: [Character: Character] = [
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "A": "ₐ", "E": "ₑ", "H": "ₕ", "I": "ᵢ", "J": "ⱼ", "K": "ₖ",
        "L": "ₗ", "M": "ₘ", "N": "ₙ", "O": "ₒ", "P": "ₚ", "R": "ᵣ",
        "S": "ₛ", "T": "ₜ", "U": "ᵤ", "V": "ᵥ", "X": "ₓ",
    ]

    /// Unicode superscript letters (common free indices).
    private static let superscriptLetterMap: [Character: Character] = [
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ",
        "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ",
        "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ",
        "W": "ᵂ",
    ]

    private static func applyFunctionOfITN(_ text: String) -> String {
        var result = text
        // Longest arity first: 3-and → 2-and → comma → single.
        result = applyFnOfAndArgs(result, pattern: functionOfThreeITNPattern, arity: 3)
        result = applyFnOfAndArgs(result, pattern: functionOfTwoITNPattern, arity: 2)
        result = applyFnOfCommaArgs(result)
        result = applyFnOfAndArgs(result, pattern: functionOfITNPattern, arity: 1)
        return result
    }

    private static func applyFnOfAndArgs(
        _ text: String,
        pattern: NSRegularExpression,
        arity: Int
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            // Groups: 1=fn, 2..=args (arity groups)
            guard match.numberOfRanges >= arity + 2,
                  let fnRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let fn = String(result[fnRange])
            var args: [String] = []
            var ok = true
            for i in 0..<arity {
                guard let ar = Range(match.range(at: 2 + i), in: result) else {
                    ok = false
                    break
                }
                args.append(rangeDigits(from: String(result[ar])))
            }
            guard ok else { continue }
            result.replaceSubrange(fullRange, with: "\(fn)(\(args.joined(separator: ", ")))")
        }
        return result
    }

    private static func applyFnOfCommaArgs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = functionOfCommaITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            // Groups: 1=fn, 2=a, 3=b, 4=c?
            guard match.numberOfRanges >= 4,
                  let fnRange = Range(match.range(at: 1), in: result),
                  let aRange = Range(match.range(at: 2), in: result),
                  let bRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let fn = String(result[fnRange])
            var args = [
                rangeDigits(from: String(result[aRange])),
                rangeDigits(from: String(result[bRange])),
            ]
            if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound,
               let cRange = Range(match.range(at: 4), in: result)
            {
                args.append(rangeDigits(from: String(result[cRange])))
            }
            result.replaceSubrange(fullRange, with: "\(fn)(\(args.joined(separator: ", ")))")
        }
        return result
    }

    private static func applyTupleOfITN(_ text: String) -> String {
        var result = text
        // Matrix multi-row before bare row-of (so "matrix row …" is not partial).
        result = applyMatrixRowsITN(result)
        // Three-arg collections first.
        result = applyAndArgsCollection(result, pattern: tupleOfThreeITNPattern, open: "(", close: ")", arity: 3)
        result = applyAndArgsCollection(result, pattern: setOfThreeITNPattern, open: "{", close: "}", arity: 3)
        result = applyAndArgsCollection(result, pattern: rowOfThreeITNPattern, open: "[", close: "]", arity: 3)
        result = applyColumnOfITN(result, pattern: columnOfThreeITNPattern, arity: 3)
        // Two-arg
        result = applyAndArgsCollection(result, pattern: tupleOfTwoITNPattern, open: "(", close: ")", arity: 2)
        result = applyAndArgsCollection(result, pattern: setOfTwoITNPattern, open: "{", close: "}", arity: 2)
        result = applyAndArgsCollection(result, pattern: rowOfTwoITNPattern, open: "[", close: "]", arity: 2)
        result = applyColumnOfITN(result, pattern: columnOfTwoITNPattern, arity: 2)
        // Comma-separated sets
        result = applySetOfCommaITN(result)
        // Empty set + intervals
        result = applyEmptySetITN(result)
        result = applyIntervalFromToITN(result)
        // Set ops (A ∪ B) + topology/set ops + vector norm + linear-algebra ops
        result = applySetOpITN(result)
        result = applyTopologySetITN(result)
        result = applyNormOfITN(result)
        result = applyLinAlgOpITN(result)
        result = applyMatmulITN(result)
        result = applyKroneckerDirectSumITN(result)
        result = applyFundamentalSpaceITN(result)
        result = applySpanITN(result)
        result = applyDimITN(result)
        result = applyOrthoCondProjITN(result)
        result = applyRelProdArgITN(result)
        result = applyQuantLogicITN(result)
        // After suffix linAlg so "eigenvalues of A transpose" → λ(Aᵀ)
        result = applyEigenDetITN(result)
        return result
    }

    /// "for all x" / "for every n" / "forall x" → ∀x
    private static let forAllVarITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:for\s+all|for\s+every|forall)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "there exists unique x" / "unique exists x" → ∃!x (before bare exists)
    private static let existsUniqueVarITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:there\s+exists\s+unique|unique\s+exists|exists\s+unique)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "there exists x" / "exists y" → ∃x
    private static let existsVarITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:there\s+exists|exists)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A implies B" → A ⇒ B
    private static let impliesITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+implies\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A maps to B" → A ↦ B
    private static let mapsToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+maps\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "sup of S" / "supremum of S" / "inf of S" / "infimum of S"
    private static let supInfOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(supremum|sup|infimum|inf)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// Quantifiers with bound vars, implies, maps-to, sup/inf (free-dict logic/analysis).
    private static func applyQuantLogicITN(_ text: String) -> String {
        var result = text
        // Unique-exists before bare exists.
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = existsUniqueVarITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let vRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let v = String(result[vRange])
                if isArticleVarFollowedByProse(varLetter: v, after: fullRange.upperBound, in: result) {
                    continue
                }
                result.replaceSubrange(fullRange, with: "∃!\(v)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = forAllVarITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let vRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let v = String(result[vRange])
                result.replaceSubrange(fullRange, with: "∀\(v)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = existsVarITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let vRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let v = String(result[vRange])
                // "there exists a chance" — article "a" + prose word, not math ∃a.
                if isArticleVarFollowedByProse(varLetter: v, after: fullRange.upperBound, in: result) {
                    continue
                }
                result.replaceSubrange(fullRange, with: "∃\(v)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = impliesITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⇒ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = mapsToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ↦ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = supInfOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let opRange = Range(match.range(at: 1), in: result),
                      let sRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let s = String(result[sRange])
                let head = (op == "sup" || op == "supremum") ? "sup" : "inf"
                result.replaceSubrange(fullRange, with: "\(head)(\(s))")
            }
        }
        return result
    }

    /// True when bound letter is article "a" and the next token is a multi-letter
    /// word — English "there exists a chance", not math "∃a".
    private static func isArticleVarFollowedByProse(
        varLetter: String,
        after: String.Index,
        in text: String
    ) -> Bool {
        guard varLetter.lowercased() == "a" else { return false }
        let rest = text[after...]
        return rest.range(of: #"^\s+[A-Za-z]{2,}\b"#, options: .regularExpression) != nil
    }

    /// "A orthogonal to B" / "A is perpendicular to B" → A ⊥ B
    private static let orthogonalToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?(?:orthogonal|perpendicular)\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A parallel to B" / "A is parallel to B" → A ∥ B
    private static let parallelToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?parallel\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "dot product of u and v" / "inner product of u and v" → ⟨u, v⟩
    private static let innerProductOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:dot|inner)\s+product\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "cross product of u and v" → u × v
    private static let crossProductOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?cross\s+product\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "argmin of f" / "arg min of f" / "argmax of g"
    private static let argMinMaxOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\barg\s*(min|max)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "orthogonal complement of V" / "orthocomplement of V" → V⊥
    private static let orthoComplementOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:orthogonal\s+complement|orthocomplement)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "condition number of A" / "cond of A" → κ(A)
    private static let conditionNumberOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:condition\s+number|cond)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "projection of u onto v" / "proj of u onto v" → proj_v(u)
    private static let projectionOfOntoITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:projection|proj)\s+of\s+([A-Za-z])\s+onto\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "projection onto V" / "proj onto V" → proj_V
    private static let projectionOntoITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:projection|proj)\s+onto\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// transpose / inverse / dagger / hermitian / trace / rank / pseudoinverse of letter.
    private static let linAlgOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(transpose|inverse|hermitian|trace|rank|pseudoinverse|moore[-\s]?penrose)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A transpose" / "A inverse" / "A dagger" / "A hermitian" / "A pseudoinverse"
    private static let linAlgSuffixITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(transpose(?:d)?|inverse|dagger|hermitian|pseudoinverse)\b"#,
            options: .caseInsensitive
        )
    }()

    /// "span of u and v and w" / "span of u and v" / "span of v"
    private static let spanOfThreeITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?span\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let spanOfTwoITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?span\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let spanOfOneITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?span\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "dimension of V" / "dim of V"
    private static let dimOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(dimension|dim)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A matmul B" / "A matrix multiply B" / "A matrix times B"
    /// Bare "A times B" is intentionally excluded (false-positives: "a times a day").
    private static let matmulInfixITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:matmul|matrix\s+(?:multiply|times|product))\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "matrix product of A and B" / "matrix multiply of A and B"
    private static let matmulOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bmatrix\s+(?:product|multiply|multiplication)\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// eigenvalues / eigenvectors / det of letter, optionally already-suffixed (Aᵀ).
    /// Prefer letter+suffix over bare letter: `\b` after A fires before Unicode
    /// superscripts (⁻¹/ᵀ/† are non-word), which wrongly yielded `det(A)⁻¹`.
    private static let eigenDetOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(eigenvalues?|eigenvectors?|determinant|det)\s+of\s+([A-Za-z](?:ᵀ|⁻¹|†)|[A-Za-z])(?!\w)"#,
            options: .caseInsensitive
        )
    }()

    /// "A tensor B" / "A kronecker B" / "A kron B"
    private static let kroneckerInfixITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:tensor|kronecker|kron)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "kronecker product of A and B" / "tensor product of A and B"
    private static let kroneckerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:kronecker|tensor)\s+product\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A direct sum B"
    private static let directSumInfixITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+direct\s+sum\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "direct sum of A and B" — both sides must be single letters (not "of money").
    private static let directSumOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bdirect\s+sum\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// null space / nullspace / kernel / column space / row space of single-letter matrix.
    private static let fundamentalSpaceOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(null\s*space|kernel|column\s+space|row\s+space)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applyLinAlgOpITN(_ text: String) -> String {
        var result = text
        // "of" forms first
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = linAlgOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let opRange = Range(match.range(at: 1), in: result),
                      let mRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let m = String(result[mRange])
                guard let written = linAlgWritten(op: op, matrix: m) else { continue }
                result.replaceSubrange(fullRange, with: written)
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = linAlgSuffixITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let mRange = Range(match.range(at: 1), in: result),
                      let opRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let m = String(result[mRange])
                var op = String(result[opRange]).lowercased()
                if op == "transposed" { op = "transpose" }
                guard let written = linAlgWritten(op: op, matrix: m) else { continue }
                result.replaceSubrange(fullRange, with: written)
            }
        }
        return result
    }

    private static func applyMatmulITN(_ text: String) -> String {
        var result = text
        // "matrix product of A and B" first (longer cue)
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = matmulOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a)\(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = matmulInfixITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a)\(b)")
            }
        }
        return result
    }

    private static func applyKroneckerDirectSumITN(_ text: String) -> String {
        var result = text
        // "of" forms first (longer cues)
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = kroneckerOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⊗ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = directSumOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⊕ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = kroneckerInfixITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⊗ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = directSumInfixITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⊕ \(b)")
            }
        }
        return result
    }

    private static func applyFundamentalSpaceITN(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        let matches = fundamentalSpaceOfITNPattern.matches(in: result, range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let opRange = Range(match.range(at: 1), in: result),
                  let mRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let op = String(result[opRange]).lowercased()
                .replacingOccurrences(of: " ", with: "")
            let m = String(result[mRange])
            guard let written = fundamentalSpaceWritten(op: op, matrix: m) else { continue }
            result.replaceSubrange(fullRange, with: written)
        }
        return result
    }

    private static func applyEigenDetITN(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        let matches = eigenDetOfITNPattern.matches(in: result, range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let opRange = Range(match.range(at: 1), in: result),
                  let mRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let op = String(result[opRange]).lowercased()
            let m = String(result[mRange])
            guard let written = eigenDetWritten(op: op, matrix: m) else { continue }
            result.replaceSubrange(fullRange, with: written)
        }
        return result
    }

    private static func linAlgWritten(op: String, matrix m: String) -> String? {
        let key = op.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        switch key {
        case "transpose":
            return "\(m)ᵀ"
        case "inverse":
            return "\(m)⁻¹"
        case "dagger", "hermitian":
            return "\(m)†"
        case "trace":
            return "tr(\(m))"
        case "rank":
            return "rank(\(m))"
        case "pseudoinverse", "moore penrose":
            return "\(m)⁺"
        default:
            return nil
        }
    }

    private static func applySpanITN(_ text: String) -> String {
        var result = text
        // Three, then two, then one (longer first).
        for (pattern, arity) in [
            (spanOfThreeITNPattern, 3),
            (spanOfTwoITNPattern, 2),
            (spanOfOneITNPattern, 1),
        ] as [(NSRegularExpression, Int)] {
            let range = NSRange(result.startIndex..., in: result)
            let matches = pattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= arity + 1,
                      let fullRange = Range(match.range, in: result) else { continue }
                var args: [String] = []
                var ok = true
                for i in 0..<arity {
                    guard let ar = Range(match.range(at: 1 + i), in: result) else {
                        ok = false
                        break
                    }
                    args.append(String(result[ar]))
                }
                guard ok else { continue }
                result.replaceSubrange(fullRange, with: "span{\(args.joined(separator: ", "))}")
            }
        }
        return result
    }

    private static func applyDimITN(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        let matches = dimOfITNPattern.matches(in: result, range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let mRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let m = String(result[mRange])
            result.replaceSubrange(fullRange, with: "dim(\(m))")
        }
        return result
    }

    /// Orthogonal complement, condition number, projection (pure free-dict LA).
    private static func applyOrthoCondProjITN(_ text: String) -> String {
        var result = text
        // Longer "of … onto …" before bare "onto …"
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = projectionOfOntoITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let uRange = Range(match.range(at: 1), in: result),
                      let vRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let u = String(result[uRange])
                let v = String(result[vRange])
                result.replaceSubrange(fullRange, with: "proj_\(v)(\(u))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = projectionOntoITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let vRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let v = String(result[vRange])
                result.replaceSubrange(fullRange, with: "proj_\(v)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = orthoComplementOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let mRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let m = String(result[mRange])
                result.replaceSubrange(fullRange, with: "\(m)⊥")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = conditionNumberOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let mRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let m = String(result[mRange])
                result.replaceSubrange(fullRange, with: "κ(\(m))")
            }
        }
        return result
    }

    /// Orthogonal/parallel relations, inner/cross products, argmin/argmax.
    private static func applyRelProdArgITN(_ text: String) -> String {
        var result = text
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = orthogonalToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⊥ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = parallelToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ∥ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = innerProductOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "⟨\(a), \(b)⟩")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = crossProductOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) × \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = argMinMaxOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let kindRange = Range(match.range(at: 1), in: result),
                      let fRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let kind = String(result[kindRange]).lowercased()
                let f = String(result[fRange])
                result.replaceSubrange(fullRange, with: "arg\(kind)(\(f))")
            }
        }
        return result
    }

    private static func fundamentalSpaceWritten(op: String, matrix m: String) -> String? {
        switch op {
        case "nullspace":
            return "N(\(m))"
        case "kernel":
            return "ker(\(m))"
        case "columnspace":
            return "C(\(m))"
        case "rowspace":
            return "R(\(m))"
        default:
            return nil
        }
    }

    private static func eigenDetWritten(op: String, matrix m: String) -> String? {
        switch op {
        case "eigenvalue", "eigenvalues":
            return "λ(\(m))"
        case "eigenvector", "eigenvectors":
            return "V(\(m))"
        case "determinant", "det":
            return "det(\(m))"
        default:
            return nil
        }
    }

    /// "A union B" / "A cup B" / "union of A and B" → A ∪ B
    private static let setOpInfixITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(union|intersection|intersect|cup|cap|setminus|without)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static let setOpOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(union|intersection)\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A proper subset of B" / "A subset of B" / "A subseteq B" / superset forms.
    /// Proper first so "proper subset" is not eaten as "subset".
    private static let subsetRelITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(proper\s+subset\s+of|subset\s+or\s+equal|subseteq|subset\s+of|proper\s+superset\s+of|superseteq|superset\s+of)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "x such that" → "x s.t." (letter-cued; bare "such that" stays prose)
    private static let suchThatITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+such\s+that\b"#,
            options: .caseInsensitive
        )
    }()

    /// "lim sup of a" / "limit superior of a" / lim inf / limit inferior
    private static let limSupInfOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:lim\s+sup|limit\s+superior|lim\s+inf|limit\s+inferior)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "power set of S" → 𝒫(S)
    private static let powerSetOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?power\s+set\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "closure of S" / "interior of S" / "boundary of S"
    private static let topologyOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(closure|interior|boundary)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "complement of S" — not "orthogonal complement" / "orthocomplement".
    /// Word boundary before complement so "orthocomplement" is not a substring hit.
    private static let setComplementOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![Oo]rthogonal\s)\b(?:the\s+)?complement\s+of\s+([A-Za-z])\b"#,
            options: []
        )
    }()

    /// "cardinality of S" / "card of S" → |S|
    private static let cardinalityOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:cardinality|card)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "diameter of S" / "diam of S" → diam(S)
    private static let diameterOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:diameter|diam)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "convex hull of S" → conv(S)
    private static let convexHullOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?convex\s+hull\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// Radius token: digit run or single letter (after SpokenNumberITN).
    private static let ballRadiusToken = #"(?:\d+(?:\.\d+)?|[A-Za-z])"#

    /// "open|closed|∅ ball of radius r around|at x"
    private static let ballRadiusFirstITNPattern: NSRegularExpression = {
        let r = ballRadiusToken
        let pattern =
            #"\b(?:the\s+)?(open|closed)?\s*ball\s+(?:of\s+)?radius\s+("# + r
            + #")\s+(?:centered\s+)?(?:at|around)\s+([A-Za-z])\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "open|closed ball around|at x of radius r"
    private static let ballCenterFirstITNPattern: NSRegularExpression = {
        let r = ballRadiusToken
        let pattern =
            #"\b(?:the\s+)?(open|closed)?\s*ball\s+(?:centered\s+)?(?:at|around)\s+([A-Za-z])\s+(?:of\s+)?radius\s+("#
            + r + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// "neighborhood of x" → N(x)
    private static let neighborhoodOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?neighborhood\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "distance from x to y" → d(x, y)
    private static let distanceFromToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?distance\s+from\s+([A-Za-z])\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "distance between x and y" → d(x, y)
    private static let distanceBetweenITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?distance\s+between\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "angle between u and v" → ∠(u, v)
    private static let angleBetweenITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?angle\s+between\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A (is) isomorphic to B" → A ≅ B
    private static let isomorphicToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?isomorphic\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A (is) homeomorphic to B" → A ≃ B
    private static let homeomorphicToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?homeomorphic\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "homomorphism from A to B" → Hom(A, B)
    private static let homomorphismFromToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?homomorphism\s+from\s+([A-Za-z])\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "a congruent to b mod n" / "a is congruent to b modulo n"
    /// Modulus: digit run or single letter (after SpokenNumberITN).
    private static let congruentModITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?congruent\s+to\s+([A-Za-z])\s+(?:mod|modulo)\s+(\d+|[A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "endomorphism of A" / "automorphism of A" → End(A) / Aut(A)
    private static let endAutOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(endomorphism|automorphism)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A injects into|to B" → A ↪ B
    private static let injectsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+injects\s+(?:into|to)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A surjects onto|to B" → A ↠ B
    private static let surjectsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+surjects\s+(?:onto|to)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A bijects onto|to B" → A ⤖ B
    private static let bijectsITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+bijects\s+(?:onto|to)\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "image of f" / "im of f" / "cokernel of f" / "coker of f" / "coimage of f"
    private static let imageCokerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(image|im|cokernel|coker|coimage|coim)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A does not divide B" (before bare divides)
    private static let doesNotDivideITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+does\s+not\s+divide\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A divides B" → A ∣ B
    private static let dividesITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+divides\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "A (is) coprime to B" / "A relatively prime to B" → gcd(A, B) = 1
    private static let coprimeToITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b([A-Za-z])\s+(?:is\s+)?(?:coprime|relatively\s+prime)\s+to\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "order of g" / "ord of g" → ord(g)
    private static let orderOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:order|ord)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "index of H in G" → [G:H]
    private static let indexOfInITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?index\s+of\s+([A-Za-z])\s+in\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "phi of n" / "euler totient of n" / "euler phi of n" → φ(n)
    private static let eulerPhiOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:euler\s+totient|euler\s+phi|phi)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "center of G" / "centre of G" → Z(G)
    private static let centerOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?cent(?:er|re)\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "centralizer of H in G" → C_G(H); "normalizer of H in G" → N_G(H)
    private static let centralizerNormalizerInITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(centralizer|normalizer)\s+of\s+([A-Za-z])\s+in\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "commutator of a and b" → [a, b]
    private static let commutatorOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?commutator\s+of\s+([A-Za-z])\s+and\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// "derived subgroup of G" / "commutator subgroup of G" → G'
    private static let derivedSubgroupOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:derived|commutator)\s+subgroup\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    /// Power set, closure, interior, boundary, complement, cardinality,
    /// diameter, convex hull, open/closed balls, neighborhood.
    private static func applyTopologySetITN(_ text: String) -> String {
        var result = text
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = powerSetOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                result.replaceSubrange(fullRange, with: "𝒫(\(s))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = topologyOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let opRange = Range(match.range(at: 1), in: result),
                      let sRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let s = String(result[sRange])
                let written: String
                switch op {
                case "closure":
                    written = "cl(\(s))"
                case "interior":
                    written = "int(\(s))"
                case "boundary":
                    written = "∂\(s)"
                default:
                    continue
                }
                result.replaceSubrange(fullRange, with: written)
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = setComplementOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                result.replaceSubrange(fullRange, with: "\(s)ᶜ")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = cardinalityOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                result.replaceSubrange(fullRange, with: "|\(s)|")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = diameterOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                result.replaceSubrange(fullRange, with: "diam(\(s))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = convexHullOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                result.replaceSubrange(fullRange, with: "conv(\(s))")
            }
        }
        // Balls: radius-first then center-first (longer spoken orders).
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = ballRadiusFirstITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let rRange = Range(match.range(at: 2), in: result),
                      let xRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let kind: String? = match.range(at: 1).location != NSNotFound
                    ? Range(match.range(at: 1), in: result).map { String(result[$0]).lowercased() }
                    : nil
                let r = String(result[rRange])
                let x = String(result[xRange])
                result.replaceSubrange(fullRange, with: ballWritten(kind: kind, center: x, radius: r))
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = ballCenterFirstITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let xRange = Range(match.range(at: 2), in: result),
                      let rRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let kind: String? = match.range(at: 1).location != NSNotFound
                    ? Range(match.range(at: 1), in: result).map { String(result[$0]).lowercased() }
                    : nil
                let x = String(result[xRange])
                let r = String(result[rRange])
                result.replaceSubrange(fullRange, with: ballWritten(kind: kind, center: x, radius: r))
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = neighborhoodOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let xRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let x = String(result[xRange])
                result.replaceSubrange(fullRange, with: "N(\(x))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = distanceFromToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "d(\(a), \(b))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = distanceBetweenITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "d(\(a), \(b))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = angleBetweenITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "∠(\(a), \(b))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = isomorphicToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ≅ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = homeomorphicToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ≃ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = homomorphismFromToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "Hom(\(a), \(b))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = congruentModITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let mRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                let m = String(result[mRange])
                result.replaceSubrange(fullRange, with: "\(a) ≡ \(b) (mod \(m))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = endAutOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let opRange = Range(match.range(at: 1), in: result),
                      let aRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let a = String(result[aRange])
                let head = op.hasPrefix("auto") ? "Aut" : "End"
                result.replaceSubrange(fullRange, with: "\(head)(\(a))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = injectsITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ↪ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = surjectsITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ↠ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = bijectsITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ⤖ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = imageCokerOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let opRange = Range(match.range(at: 1), in: result),
                      let fRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let f = String(result[fRange])
                let head: String
                switch op {
                case "image", "im":
                    head = "im"
                case "cokernel", "coker":
                    head = "coker"
                case "coimage", "coim":
                    head = "coim"
                default:
                    continue
                }
                result.replaceSubrange(fullRange, with: "\(head)(\(f))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = doesNotDivideITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ∤ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = dividesITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "\(a) ∣ \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = coprimeToITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "gcd(\(a), \(b)) = 1")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = orderOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let gRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let g = String(result[gRange])
                result.replaceSubrange(fullRange, with: "ord(\(g))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = indexOfInITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let hRange = Range(match.range(at: 1), in: result),
                      let gRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let h = String(result[hRange])
                let g = String(result[gRange])
                result.replaceSubrange(fullRange, with: "[\(g):\(h)]")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = eulerPhiOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let nRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let n = String(result[nRange])
                result.replaceSubrange(fullRange, with: "φ(\(n))")
            }
        }
        // centralizer/normalizer "… in G" before bare center (no conflict).
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = centralizerNormalizerInITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let opRange = Range(match.range(at: 1), in: result),
                      let hRange = Range(match.range(at: 2), in: result),
                      let gRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let h = String(result[hRange])
                let g = String(result[gRange])
                let head = op.hasPrefix("norm") ? "N" : "C"
                result.replaceSubrange(fullRange, with: "\(head)_\(g)(\(h))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = centerOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let gRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let g = String(result[gRange])
                result.replaceSubrange(fullRange, with: "Z(\(g))")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = commutatorOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let aRange = Range(match.range(at: 1), in: result),
                      let bRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                result.replaceSubrange(fullRange, with: "[\(a), \(b)]")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = derivedSubgroupOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let gRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let g = String(result[gRange])
                result.replaceSubrange(fullRange, with: "\(g)'")
            }
        }
        return result
    }

    private static func ballWritten(kind: String?, center x: String, radius r: String) -> String {
        switch kind {
        case "closed":
            return "B̄(\(x), \(r))"
        default:
            // open or unspecified ball
            return "B(\(x), \(r))"
        }
    }

    /// "norm of v" / "L2 norm of v" / "frobenius norm of A" / "infinity norm of v"
    /// Group 1 = optional kind (l2|frobenius|infinity|inf); group 2 = letter.
    private static let normOfITNPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:(l2|frobenius|infinity|inf)\s+)?norm\s+of\s+([A-Za-z])\b"#,
            options: .caseInsensitive
        )
    }()

    private static func applySetOpITN(_ text: String) -> String {
        var result = text
        // "union of A and B" first
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = setOpOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let opRange = Range(match.range(at: 1), in: result),
                      let aRange = Range(match.range(at: 2), in: result),
                      let bRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let op = String(result[opRange]).lowercased()
                let a = String(result[aRange])
                let b = String(result[bRange])
                let sym = op.hasPrefix("inter") ? "∩" : "∪"
                result.replaceSubrange(fullRange, with: "\(a) \(sym) \(b)")
            }
        }
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = setOpInfixITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let aRange = Range(match.range(at: 1), in: result),
                      let opRange = Range(match.range(at: 2), in: result),
                      let bRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                let op = String(result[opRange]).lowercased()
                let sym: String
                switch op {
                case "union", "cup":
                    sym = "∪"
                case "intersection", "intersect", "cap":
                    sym = "∩"
                case "setminus", "without":
                    sym = "∖"
                default:
                    continue
                }
                result.replaceSubrange(fullRange, with: "\(a) \(sym) \(b)")
            }
        }
        // Subset / superset relations
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = subsetRelITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 4,
                      let aRange = Range(match.range(at: 1), in: result),
                      let opRange = Range(match.range(at: 2), in: result),
                      let bRange = Range(match.range(at: 3), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let a = String(result[aRange])
                let b = String(result[bRange])
                let op = String(result[opRange]).lowercased()
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                let sym: String
                switch op {
                case "proper subset of":
                    sym = "⊂"
                case "subset of", "subseteq", "subset or equal":
                    sym = "⊆"
                case "proper superset of":
                    sym = "⊃"
                case "superset of", "superseteq":
                    sym = "⊇"
                default:
                    continue
                }
                result.replaceSubrange(fullRange, with: "\(a) \(sym) \(b)")
            }
        }
        // "x such that" → "x s.t."
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = suchThatITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let xRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let x = String(result[xRange])
                result.replaceSubrange(fullRange, with: "\(x) s.t.")
            }
        }
        // lim sup / lim inf of letter
        do {
            let range = NSRange(result.startIndex..., in: result)
            let matches = limSupInfOfITNPattern.matches(in: result, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let sRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let s = String(result[sRange])
                let full = String(result[fullRange]).lowercased()
                let head = (full.contains("sup") || full.contains("superior")) ? "limsup" : "liminf"
                result.replaceSubrange(fullRange, with: "\(head)(\(s))")
            }
        }
        return result
    }

    private static func applyNormOfITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = normOfITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            // Groups: 1=kind?, 2=var
            guard match.numberOfRanges >= 3,
                  let varRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let v = String(result[varRange])
            let kind: String? = {
                guard match.range(at: 1).location != NSNotFound,
                      let kr = Range(match.range(at: 1), in: result) else { return nil }
                return String(result[kr]).lowercased()
            }()
            let written: String
            switch kind {
            case "l2":
                written = "‖\(v)‖₂"
            case "frobenius":
                written = "‖\(v)‖_F"
            case "infinity", "inf":
                written = "‖\(v)‖_∞"
            default:
                written = "‖\(v)‖"
            }
            result.replaceSubrange(fullRange, with: written)
        }
        return result
    }

    /// Column vector: args stacked as [[a], [b], …]
    private static func applyColumnOfITN(
        _ text: String,
        pattern: NSRegularExpression,
        arity: Int
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= arity + 1,
                  let fullRange = Range(match.range, in: result) else { continue }
            var args: [String] = []
            var ok = true
            for i in 0..<arity {
                guard let ar = Range(match.range(at: 1 + i), in: result) else {
                    ok = false
                    break
                }
                args.append(rangeDigits(from: String(result[ar])))
            }
            guard ok else { continue }
            let cells = args.map { "[\($0)]" }.joined(separator: ", ")
            result.replaceSubrange(fullRange, with: "[\(cells)]")
        }
        return result
    }

    private static func applyEmptySetITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = emptySetITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result) else { continue }
            result.replaceSubrange(full, with: "∅")
        }
        return result
    }

    private static func applyIntervalFromToITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = intervalFromToITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let kindRange = Range(match.range(at: 1), in: result),
                  let loRange = Range(match.range(at: 2), in: result),
                  let hiRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let kind = String(result[kindRange]).lowercased()
            let lo = rangeDigits(from: String(result[loRange]))
            let hi = rangeDigits(from: String(result[hiRange]))
            let brackets: (String, String)
            switch kind {
            case "closed":
                brackets = ("[", "]")
            case "open":
                brackets = ("(", ")")
            case "half open", "left closed":
                brackets = ("[", ")")
            case "right closed":
                brackets = ("(", "]")
            default:
                continue
            }
            result.replaceSubrange(
                fullRange,
                with: "\(brackets.0)\(lo), \(hi)\(brackets.1)"
            )
        }
        return result
    }

    private static func applyAndArgsCollection(
        _ text: String,
        pattern: NSRegularExpression,
        open: String,
        close: String,
        arity: Int
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= arity + 1,
                  let fullRange = Range(match.range, in: result) else { continue }
            var args: [String] = []
            var ok = true
            for i in 0..<arity {
                guard let ar = Range(match.range(at: 1 + i), in: result) else {
                    ok = false
                    break
                }
                args.append(rangeDigits(from: String(result[ar])))
            }
            guard ok else { continue }
            result.replaceSubrange(
                fullRange,
                with: "\(open)\(args.joined(separator: ", "))\(close)"
            )
        }
        return result
    }

    private static func applySetOfCommaITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = setOfCommaITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let aRange = Range(match.range(at: 1), in: result),
                  let bRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            var args = [
                rangeDigits(from: String(result[aRange])),
                rangeDigits(from: String(result[bRange])),
            ]
            if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
               let cRange = Range(match.range(at: 3), in: result)
            {
                args.append(rangeDigits(from: String(result[cRange])))
            }
            result.replaceSubrange(fullRange, with: "{\(args.joined(separator: ", "))}")
        }
        return result
    }

    /// "matrix row of 1 and 2 next row of 3 and 4" → [[1, 2], [3, 4]]
    /// String-scan (not one big regex) so multi-row forms stay reliable.
    private static func applyMatrixRowsITN(_ text: String) -> String {
        let lower = text.lowercased()
        var searchFrom = lower.startIndex
        var replacements: [(Range<String.Index>, String)] = []
        while let matrixRange = lower.range(of: "matrix row of ", range: searchFrom..<lower.endIndex) {
            // Align indices with original `text` (same UTF-16 layout as lowercased ASCII keywords).
            let start = matrixRange.lowerBound
            // Body starts at "row of …" (skip "matrix ").
            guard let rowStart = lower.range(of: "row of ", range: start..<lower.endIndex)?.lowerBound
            else { break }
            // Consume successive "row of …" linked by " next row of ".
            var cursor = rowStart
            var rowFrags: [String] = []
            while true {
                guard let fragEnd = endIndexOfRowOf(in: lower, from: cursor) else { break }
                let frag = String(text[cursor..<fragEnd])
                guard parseRowOfAndArgs(frag) != nil else { break }
                rowFrags.append(frag)
                // Look for "next row of " (optional leading spaces already skipped by frag end).
                let after = fragEnd
                var restStart = after
                while restStart < lower.endIndex, lower[restStart].isWhitespace {
                    restStart = lower.index(after: restStart)
                }
                let rest = lower[restStart...]
                if rest.hasPrefix("next row of ") {
                    // Land on "row of " for the following fragment.
                    cursor = lower.index(restStart, offsetBy: "next ".count)
                    continue
                }
                // Done with this matrix — full span is start..<fragEnd
                if rowFrags.count >= 2 {
                    let rows = rowFrags.compactMap { parseRowOfAndArgs($0) }
                    if rows.count == rowFrags.count {
                        let rendered = rows
                            .map { "[\($0.joined(separator: ", "))]" }
                            .joined(separator: ", ")
                        replacements.append((start..<fragEnd, "[\(rendered)]"))
                    }
                }
                searchFrom = fragEnd
                break
            }
            if cursor == rowStart {
                // Failed to parse even first row — advance past "matrix "
                searchFrom = lower.index(start, offsetBy: 1)
            }
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for (range, rep) in replacements.reversed() {
            result.replaceSubrange(range, with: rep)
        }
        return result
    }

    /// End index of "row of A and B [and C]" starting at `from` (must be on "row").
    private static func endIndexOfRowOf(in lower: String, from: String.Index) -> String.Index? {
        guard lower[from...].hasPrefix("row of ") else { return nil }
        var i = lower.index(from, offsetBy: "row of ".count)
        var args = 0
        var expectAnd = false
        while i < lower.endIndex {
            // Skip spaces
            while i < lower.endIndex, lower[i].isWhitespace {
                i = lower.index(after: i)
            }
            guard i < lower.endIndex else { break }
            // Peek next word
            let wordStart = i
            while i < lower.endIndex, !lower[i].isWhitespace {
                i = lower.index(after: i)
            }
            let word = String(lower[wordStart..<i])
            if expectAnd {
                if word == "and" {
                    expectAnd = false
                    continue
                }
                // End of row-of before this word
                return wordStart
            }
            // Arg?
            let dig = rangeDigits(from: word)
            let isArg =
                (word.count == 1 && word.first!.isLetter)
                || dig.allSatisfy(\.isNumber)
            if isArg {
                args += 1
                if args > 3 { return nil }
                expectAnd = true
                continue
            }
            // Not an arg — end before this word (if we have enough args)
            return args >= 2 ? wordStart : nil
        }
        return args >= 2 && expectAnd ? i : nil
    }

    /// Parse "row of A and B [and C]" → [A, B, C] digit-normalized.
    private static func parseRowOfAndArgs(_ fragment: String) -> [String]? {
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("row of ") else { return nil }
        let ofPrefix = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        let tokens = ofPrefix.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // tokens like ["1", "and", "2", "and", "3"] or ["a", "and", "b"]
        var args: [String] = []
        var expectAnd = false
        for t in tokens {
            let c = t.lowercased()
            if expectAnd {
                guard c == "and" else { return nil }
                expectAnd = false
                continue
            }
            let dig = rangeDigits(from: t)
            let isArg =
                (t.count == 1 && t.first!.isLetter)
                || dig.allSatisfy(\.isNumber)
            guard isArg else { return nil }
            args.append(dig.allSatisfy(\.isNumber) ? dig : String(t))
            expectAnd = true
        }
        // Last token must be an arg (expectAnd true means we ended on arg).
        guard expectAnd, args.count >= 2, args.count <= 3 else { return nil }
        return args
    }

    private static func applySubscriptITN(_ text: String) -> String {
        var result = applyIndexScriptITN(text, pattern: subscriptITNPattern, format: formatSubscriptIndex)
        result = applyIndexScriptITN(result, pattern: superscriptITNPattern, format: formatSuperscriptIndex)
        return result
    }

    private static func applyIndexScriptITN(
        _ text: String,
        pattern: NSRegularExpression,
        format: (String) -> String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let baseRange = Range(match.range(at: 1), in: result),
                  let idxRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let base = String(result[baseRange])
            let idxRaw = String(result[idxRange])
            result.replaceSubrange(fullRange, with: base + format(idxRaw))
        }
        return result
    }

    private static func formatSubscriptIndex(_ raw: String) -> String {
        // Spoken/digit numbers → subscript digits
        let asDigits = rangeDigits(from: raw)
        if asDigits.allSatisfy(\.isNumber) {
            return subscriptFromDigits(asDigits)
        }
        // Single letter → unicode subscript letter when available
        if raw.count == 1, let ch = raw.first, let sub = subscriptLetterMap[ch] {
            return String(sub)
        }
        // Fallback underscore form
        return "_\(raw)"
    }

    private static func formatSuperscriptIndex(_ raw: String) -> String {
        let asDigits = rangeDigits(from: raw)
        if asDigits.allSatisfy(\.isNumber) {
            return superscriptFromDigits(asDigits)
        }
        if raw.count == 1, let ch = raw.first {
            if let sup = superscriptLetterMap[ch] {
                return String(sup)
            }
            if let sup = superscriptLetterMap[Character(ch.lowercased())] {
                return String(sup)
            }
        }
        return "^\(raw)"
    }

    private static func applySciPowerOfITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = sciPowerOfITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let mantRange = Range(match.range(at: 1), in: result),
                  let expRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let mant = rangeDigits(from: String(result[mantRange]))
            let expDigits = rangeDigits(from: String(result[expRange]))
            result.replaceSubrange(
                fullRange,
                with: "\(mant)×10\(superscriptFromDigits(expDigits))"
            )
        }
        return result
    }

    private static func applySciNthPowerITN(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = sciNthPowerITNPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let mantRange = Range(match.range(at: 1), in: result),
                  let ordRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let mant = rangeDigits(from: String(result[mantRange]))
            let ordRaw = String(result[ordRange]).lowercased()
            let exp: Int
            if let w = ordinalPowerWords[ordRaw] {
                exp = w
            } else if let n = Int(ordRaw.filter(\.isNumber)) {
                exp = n
            } else {
                continue
            }
            result.replaceSubrange(
                fullRange,
                with: "\(mant)×10\(superscriptString(exp))"
            )
        }
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
        var raw = digits
        var negative = false
        if raw.hasPrefix("-") {
            negative = true
            raw.removeFirst()
        }
        var out = ""
        for ch in raw {
            if let s = superscriptDigits[ch] {
                out.append(s)
            } else if ch.isNumber {
                // Fallback caret form if unmapped
                return "^" + digits
            }
        }
        if out.isEmpty { return "^" + digits }
        return negative ? "⁻" + out : out
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
