// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// Pure parse; AppState executes against TextInserter + transcript buffer.
// Tolerant of ASR trailing punctuation, politeness words, and common aliases.

import Foundation

enum DictationCommand: Equatable, Sendable {
    case none
    /// Undo the last N typed segments (Dragon "scratch that" / "scratch that N times").
    /// Bare "scratch that" is `count: 1`. Count is always ≥ 1 (clamped at parse).
    case scratchThat(count: Int)
    /// Arm multi-step replace: next content undoes last phrase then inserts.
    case replaceThat
    /// Single-utterance find/replace last occurrence of `target` with `replacement`.
    case replacePhrase(target: String, replacement: String)
    /// Single-utterance delete last occurrence of `target`.
    case deletePhrase(target: String)
    /// Single-utterance select last occurrence of `target` (arms type-over).
    case selectPhrase(target: String)
    /// Move caret to start of last occurrence of `target` (no selection arm).
    case goToPhrase(target: String)
    /// Move caret to end of last occurrence of `target` (no selection arm).
    case goAfterPhrase(target: String)
    /// Dragon "resume with X": keep through last X, delete the rest, append next.
    case resumeWith(target: String)
    /// Delete the last whitespace-delimited word.
    case deleteLastWord
    /// Delete the last N whitespace-delimited words (N ≥ 2).
    case deleteLastWords(count: Int)
    /// Delete the last sentence (after [.?!] + whitespace).
    case deleteLastSentence
    /// Delete the first sentence.
    case deleteFirstSentence
    /// Delete the second sentence (session-relative "next"). Does not steal delete last/previous.
    case deleteNextSentence
    /// Delete the last paragraph (after \n\n or \n).
    case deleteLastParagraph
    /// Delete the first paragraph.
    case deleteFirstParagraph
    /// Delete the next paragraph (progressive). Does not steal delete last/previous.
    case deleteNextParagraph
    /// Delete the last line (after final \n).
    case deleteLastLine
    /// Delete the first line.
    case deleteFirstLine
    /// Delete the next line (progressive). Does not steal delete last/previous.
    case deleteNextLine
    /// Clear the entire session transcript and typed text.
    case clearAll
    /// Insert Return N times (Dragon "press enter" / "press enter N times").
    /// Session buffer + edit stack grow by N newlines. Count ≥ 1.
    case pressEnter(count: Int)
    /// Insert Tab N times (Dragon "Tab <n> times"). Count ≥ 1.
    /// Session buffer + edit stack grow by N tab characters.
    case pressTab(count: Int)
    /// Insert Space N times (Dragon-style "press space N times"). Count ≥ 1.
    /// Session buffer + edit stack grow by N spaces.
    case pressSpace(count: Int)
    /// Press Backspace / Delete N times (Dragon "Backspace <n>").
    /// Keyboard-only; session buffer / edit stack unchanged. Count ≥ 1.
    case pressBackspace(count: Int)
    /// Press Escape once. Keyboard-only; buffer unchanged; does not cancel session.
    case pressEscape
    /// System undo (⌘Z). Keyboard-only; buffer / edit stack unchanged.
    case pressUndo
    /// System redo (⌘⇧Z). Keyboard-only; buffer / edit stack unchanged.
    case pressRedo
    /// Press Forward Delete N times (right-of-caret delete).
    /// Keyboard-only; session buffer / edit stack unchanged. Count ≥ 1.
    case pressForwardDelete(count: Int)
    /// Insert today's date (e.g. "July 10, 2026").
    case insertDate
    /// Insert current local time (e.g. "3:45 p.m.").
    case insertTime
    /// Copy session transcript to the clipboard.
    case copyThat
    /// Paste from the clipboard into the focused app.
    case pasteThat
    /// Duplicate last phrase (or whole buffer): copy + append again.
    case duplicateThat
    /// Redo the last N scratched segments (Dragon multi-redo).
    /// Bare "redo that" is `count: 1`. Count ≥ 1.
    case redoThat(count: Int)
    /// Set sticky capitalization mode for following commits.
    case setCapsMode(CapsMode)
    /// Set sticky spell mode for following commits (letter packing).
    case setSpellMode(SpellMode)
    /// Set sticky no-space mode for following commits (empty segment separators).
    case setNoSpaceMode(NoSpaceMode)
    /// Select last phrase and enter spell mode (Dragon-style "spell that").
    case spellThat
    /// Capitalize the last word (one-shot).
    case capThat
    /// Capitalize the next content word / first word of next commit (one-shot arm).
    case capNext
    /// UPPERCASE the last word (one-shot).
    case allCapsThat
    /// lowercase the last word (one-shot).
    case noCapsThat
    /// Title-case the last phrase / stack delta (one-shot).
    case titleCaseThat
    /// Sentence-case the last phrase (one-shot).
    case sentenceCaseThat
    /// Remove the space before the last word / phrase (one-shot).
    case noSpaceThat
    /// On-demand AI cleanup of selection / last phrase / session buffer.
    /// Distinct from "fix that" / "correct that" (those are undo / scratch).
    case aiCleanup
    /// Select the last typed phrase (shift+left over last stack delta).
    case selectThat
    /// Select the last whitespace-delimited word.
    case selectLastWord
    /// Select last N whitespace-delimited words (session trailing). Buffer unchanged.
    case selectLastWords(count: Int)
    /// Select next word: at/after sessionCaret + arm type-over (keyboard fallback at end).
    case selectNextWord
    /// Select previous word: session trailing word + arm type-over (buffer unchanged until content).
    case selectPreviousWord
    /// Delete next word via ⇧⌥→ then backspace. Keyboard-only; buffer unchanged.
    case deleteNextWord
    /// Delete previous word via ⇧⌥← then backspace. Keyboard-only; buffer unchanged.
    case deletePreviousWord
    /// Select previous N words: session trailing N words + arm type-over (N ≥ 2).
    case selectPreviousWords(count: Int)
    /// Select next N words from sessionCaret + arm type-over (N ≥ 2; keyboard fallback at end).
    case selectNextWords(count: Int)
    /// Delete previous N words via ⇧⌥← × N then backspace. Keyboard-only.
    case deletePreviousWords(count: Int)
    /// Delete next N words via ⇧⌥→ × N then backspace. Keyboard-only.
    case deleteNextWords(count: Int)
    /// Select previous N characters (⇧← × N). Keyboard-only; buffer unchanged.
    case selectPreviousCharacters(count: Int)
    /// Select next N characters (⇧→ × N). Keyboard-only; buffer unchanged.
    case selectNextCharacters(count: Int)
    /// Delete previous N characters from session buffer (and keyboard when incremental).
    case deletePreviousCharacters(count: Int)
    /// Delete next N characters (select forward then backspace). Keyboard-only.
    case deleteNextCharacters(count: Int)
    /// Delete last N sentences from session buffer (N ≥ 2).
    case deleteLastSentences(count: Int)
    /// Delete last N paragraphs from session buffer (N ≥ 2).
    case deleteLastParagraphs(count: Int)
    /// Delete last N lines from session buffer (N ≥ 2).
    case deleteLastLines(count: Int)
    /// Select last N sentences (session trailing). Buffer unchanged.
    case selectLastSentences(count: Int)
    /// Select last N paragraphs (session trailing). Buffer unchanged.
    case selectLastParagraphs(count: Int)
    /// Select last N lines (session trailing). Buffer unchanged.
    case selectLastLines(count: Int)
    /// Select next N sentences (session-relative progressive). Buffer unchanged.
    case selectNextSentences(count: Int)
    /// Select next N paragraphs (session-relative progressive). Buffer unchanged.
    case selectNextParagraphs(count: Int)
    /// Select next N lines (session-relative progressive). Buffer unchanged.
    case selectNextLines(count: Int)
    /// Delete next N sentences (session-relative progressive).
    case deleteNextSentences(count: Int)
    /// Delete next N paragraphs (session-relative progressive).
    case deleteNextParagraphs(count: Int)
    /// Delete next N lines (session-relative progressive).
    case deleteNextLines(count: Int)
    /// Select the last sentence (after [.?!] + whitespace).
    case selectLastSentence
    /// Select the first sentence (before first [.?!] + whitespace).
    case selectFirstSentence
    /// Select the second sentence (session-relative "next"). Buffer unchanged.
    case selectNextSentence
    /// Select previous sentence (progressive; from end = last). Buffer unchanged.
    case selectPreviousSentence
    /// Select the last paragraph (after \n\n or \n).
    case selectLastParagraph
    /// Select the first paragraph (before first \n\n or \n).
    case selectFirstParagraph
    /// Select the second paragraph (session-relative "next"). Buffer unchanged.
    case selectNextParagraph
    /// Select previous paragraph (progressive; from end = last). Buffer unchanged.
    case selectPreviousParagraph
    /// Select the last line (after final \n).
    case selectLastLine
    /// Select the first line (before first \n).
    case selectFirstLine
    /// Select the next line (progressive). Buffer unchanged.
    case selectNextLine
    /// Select previous line (progressive; from end = last). Buffer unchanged.
    case selectPreviousLine
    /// Select all in the focused app (⌘A).
    case selectAll
    /// Collapse the current selection (right-arrow without shift).
    case unselectThat
    /// Select last phrase and bold (⌘B).
    case boldThat
    /// Select last phrase and italicize (⌘I).
    case italicThat
    /// Select last phrase and underline (⌘U).
    case underlineThat
    /// Select last phrase, cut to clipboard (⌘X), drop buffer delta.
    case cutThat
    /// Move cursor one word left (⌥←). Buffer unchanged.
    case moveLeftWord
    /// Move cursor one word right (⌥→). Buffer unchanged.
    case moveRightWord
    /// Move cursor N words left (⌥← × N). Buffer unchanged.
    case movePreviousWords(count: Int)
    /// Move cursor N words right (⌥→ × N). Buffer unchanged.
    case moveNextWords(count: Int)
    /// Move cursor N characters left (← × N). Buffer unchanged.
    case movePreviousCharacters(count: Int)
    /// Move cursor N characters right (→ × N). Buffer unchanged.
    case moveNextCharacters(count: Int)
    /// Move cursor N lines up (↑ × N). Dragon "move up N lines". Buffer unchanged.
    case moveUpLines(count: Int)
    /// Move cursor N lines down (↓ × N). Dragon "move down N lines". Buffer unchanged.
    case moveDownLines(count: Int)
    /// Select N lines up (⇧↑ × N). Keyboard-only; buffer unchanged. Count ≥ 1.
    case selectUpLines(count: Int)
    /// Select N lines down (⇧↓ × N). Keyboard-only; buffer unchanged. Count ≥ 1.
    case selectDownLines(count: Int)
    /// Progressive session: move caret to previous line start (dual LineCursor.tla).
    case moveToPreviousLine
    /// Progressive session: move caret to next line start (dual LineCursor.tla).
    case moveToNextLine
    /// Move cursor to line start (⌘←). Buffer unchanged.
    case moveToStart
    /// Move cursor to line end (⌘→). Buffer unchanged.
    case moveToEnd
    /// Move cursor to document start (⌘↑). Buffer unchanged.
    case moveToDocumentStart
    /// Move cursor to document end (⌘↓). Buffer unchanged.
    case moveToDocumentEnd
    /// Move caret to start of sentence under session caret (Dragon-style).
    case moveToSentenceStart
    /// Move caret to end of sentence under session caret (Dragon-style).
    case moveToSentenceEnd
    /// Move caret to start of paragraph under session caret.
    case moveToParagraphStart
    /// Move caret to end of paragraph under session caret.
    case moveToParagraphEnd
    /// Scroll N pages up (Page Up × N). Buffer unchanged. Count ≥ 1.
    case pageUp(count: Int)
    /// Scroll N pages down (Page Down × N). Buffer unchanged. Count ≥ 1.
    case pageDown(count: Int)
    /// Move cursor to start of last sentence (plain ← × n). Buffer unchanged.
    case moveToPreviousSentence
    /// Move cursor to start of second sentence (← × full, then → past first). Buffer unchanged.
    case moveToNextSentence
    /// Move cursor to start of previous paragraph (progressive). Buffer unchanged.
    case moveToPreviousParagraph
    /// Move cursor to start of next paragraph (progressive). Buffer unchanged.
    case moveToNextParagraph
    /// Move up N paragraphs (to start of paragraph). Dragon "move up N paragraphs".
    case moveUpParagraphs(count: Int)
    /// Move down N paragraphs (to start of paragraph). Dragon "move down N paragraphs".
    case moveDownParagraphs(count: Int)
    /// Move up N sentences (to start of sentence). Dragon-style counted jump.
    case moveUpSentences(count: Int)
    /// Move down N sentences (to start of sentence). Dragon-style counted jump.
    case moveDownSentences(count: Int)
    /// Select N paragraphs upward from caret (inclusive). Buffer unchanged until type-over.
    case selectUpParagraphs(count: Int)
    /// Select N paragraphs downward from caret (inclusive). Buffer unchanged until type-over.
    case selectDownParagraphs(count: Int)
    /// Select N sentences upward from caret (inclusive). Buffer unchanged until type-over.
    case selectUpSentences(count: Int)
    /// Select N sentences downward from caret (inclusive). Buffer unchanged until type-over.
    case selectDownSentences(count: Int)

    /// Parse a post-processed segment into a command, or `.none` for normal text.
    static func parse(_ text: String) -> DictationCommand {
        let candidates = normalizeCandidates(text)
        for candidate in candidates {
            if let cmd = matchExact(candidate) {
                return cmd
            }
            if let cmd = matchCounted(candidate) {
                return cmd
            }
        }
        // Phrase replace/delete use lightly cleaned original text so casing is preserved.
        if let cmd = matchPhraseReplace(text) {
            return cmd
        }
        if let cmd = matchPhraseDelete(text) {
            return cmd
        }
        if let cmd = matchPhraseSelect(text) {
            return cmd
        }
        if let cmd = matchPhraseGo(text) {
            return cmd
        }
        if let cmd = matchResumeWith(text) {
            return cmd
        }
        return .none
    }

    /// "resume with X" / "continue with X" — Dragon truncate-after-match.
    private static func matchResumeWith(_ text: String) -> DictationCommand? {
        var n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        var tokens = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        while let last = tokens.last, fillers.contains(last.lowercased()) {
            tokens.removeLast()
        }
        n = tokens.joined(separator: " ")

        let patterns = [
            #"(?i)^resume with (.+)$"#,
            #"(?i)^continue with (.+)$"#,
            #"(?i)^start again from (.+)$"#,
            #"(?i)^start over from (.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let tRange = Range(match.range(at: 1), in: n) else {
                continue
            }
            let target = String(n[tRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let low = target.lowercased()
            // Bare pronouns → not a resume target
            if low == "that" || low == "it" || low == "this" { continue }
            return .resumeWith(target: target)
        }
        return nil
    }

    /// "replace X with Y" / "change X to Y" / "swap X for Y".
    /// Does not match bare "replace that" (no with/to/for clause).
    private static func matchPhraseReplace(_ text: String) -> DictationCommand? {
        var n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Strip leading politeness
        let stripped = stripPoliteness(n.lowercased())
        // Re-apply strip on original by dropping matching leading tokens
        if stripped != n.lowercased() {
            var tokens = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
            while let first = tokens.first, fillers.contains(first.lowercased()) {
                tokens.removeFirst()
            }
            while let last = tokens.last, fillers.contains(last.lowercased()) {
                tokens.removeLast()
            }
            n = tokens.joined(separator: " ")
        }

        let specs: [(pattern: String, targetGroup: Int, replGroup: Int)] = [
            (#"(?i)^replace (.+?) with (.+)$"#, 1, 2),
            (#"(?i)^change (.+?) to (.+)$"#, 1, 2),
            (#"(?i)^swap (.+?) for (.+)$"#, 1, 2),
        ]
        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges > max(spec.targetGroup, spec.replGroup),
                  let tRange = Range(match.range(at: spec.targetGroup), in: n),
                  let rRange = Range(match.range(at: spec.replGroup), in: n) else {
                continue
            }
            let target = String(n[tRange]).trimmingCharacters(in: .whitespaces)
            let replacement = String(n[rRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !replacement.isEmpty else { continue }
            // Do not treat "replace that with …" as multi-step arm — phrase form is fine.
            // Bare "replace that" has no "with" and never reaches here.
            return .replacePhrase(target: target, replacement: replacement)
        }
        return nil
    }

    /// "delete X" / "remove X". Runs after exact/counted so structural deletes win.
    private static func matchPhraseDelete(_ text: String) -> DictationCommand? {
        var n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Strip leading/trailing politeness (preserve remaining case)
        var tokens = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        while let last = tokens.last, fillers.contains(last.lowercased()) {
            tokens.removeLast()
        }
        n = tokens.joined(separator: " ")

        let specs = [
            #"(?i)^delete (.+)$"#,
            #"(?i)^remove (.+)$"#,
        ]
        for pattern in specs {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let tRange = Range(match.range(at: 1), in: n) else {
                continue
            }
            let target = String(n[tRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let low = target.lowercased()
            // Refuse bare structural tokens already handled by matchExact
            // (defense in depth if exact match order changes).
            let blocked: Set<String> = [
                "that", "it", "last", "word", "sentence", "paragraph", "line",
                "all", "everything", "selection", "forward", "previous", "prior",
                "next", "key",
            ]
            if blocked.contains(low) { continue }
            // Refuse incomplete counted peels ("last 1 words", "previous sentence"…)
            // so invalid N does not become a phrase delete of the words "last 1 words".
            if low.hasPrefix("last ") || low.hasPrefix("previous ") || low.hasPrefix("prior ")
                || low.hasPrefix("next ") || low.hasPrefix("forward ")
                || low.hasPrefix("the last ") || low.hasPrefix("the previous ")
                || low.hasPrefix("the next ") {
                continue
            }
            return .deletePhrase(target: target)
        }
        return nil
    }

    /// "select X" / "highlight X". Runs after exact/counted so structural selects win.
    private static func matchPhraseSelect(_ text: String) -> DictationCommand? {
        var n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        var tokens = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        while let last = tokens.last, fillers.contains(last.lowercased()) {
            tokens.removeLast()
        }
        n = tokens.joined(separator: " ")

        let specs = [
            #"(?i)^select (.+)$"#,
            #"(?i)^highlight (.+)$"#,
        ]
        for pattern in specs {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let tRange = Range(match.range(at: 1), in: n) else {
                continue
            }
            let target = String(n[tRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let low = target.lowercased()
            // Bare structural tokens (exact match already won if full phrase matched).
            let blocked: Set<String> = [
                "that", "it", "last", "word", "sentence", "paragraph", "line",
                "all", "everything", "selection", "forward", "previous", "prior",
                "next", "the last word", "the last sentence", "the last paragraph",
                "the last line", "the first sentence", "the first paragraph",
                "the first line",
            ]
            if blocked.contains(low) { continue }
            // Incomplete counted / progressive forms
            if low.hasPrefix("last ") || low.hasPrefix("previous ") || low.hasPrefix("prior ")
                || low.hasPrefix("next ") || low.hasPrefix("forward ")
                || low.hasPrefix("first ") || low.hasPrefix("the last ")
                || low.hasPrefix("the previous ") || low.hasPrefix("the next ")
                || low.hasPrefix("the first ") {
                continue
            }
            return .selectPhrase(target: target)
        }
        return nil
    }

    /// "go to X" / "go after X" / Dragon "insert before X" / "insert after X".
    /// Insert-before/after only moves the caret (next content inserts); dual GoToPhrase.tla.
    /// Exact structural go-tos win first (start/end/sentence/…).
    private static func matchPhraseGo(_ text: String) -> DictationCommand? {
        var n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        var tokens = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        while let last = tokens.last, fillers.contains(last.lowercased()) {
            tokens.removeLast()
        }
        n = tokens.joined(separator: " ")

        // After-forms before to-forms so "insert after" is not eaten by a weaker prefix.
        let specs: [(pattern: String, after: Bool)] = [
            (#"(?i)^go after (.+)$"#, true),
            (#"(?i)^move after (.+)$"#, true),
            (#"(?i)^jump after (.+)$"#, true),
            (#"(?i)^insert after (.+)$"#, true),
            (#"(?i)^place after (.+)$"#, true),
            (#"(?i)^go to (.+)$"#, false),
            (#"(?i)^move to (.+)$"#, false),
            (#"(?i)^jump to (.+)$"#, false),
            (#"(?i)^insert before (.+)$"#, false),
            (#"(?i)^place before (.+)$"#, false),
        ]
        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let tRange = Range(match.range(at: 1), in: n) else {
                continue
            }
            let target = String(n[tRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let low = target.lowercased()
            // Structural destinations already handled by matchExact
            let blocked: Set<String> = [
                "start", "end", "beginning", "top", "bottom",
                "start of document", "end of document", "beginning of document",
                "top of document", "bottom of document",
                "start of the document", "end of the document",
                "beginning of line", "end of line",
                "previous sentence", "next sentence", "forward sentence",
                "previous paragraph", "next paragraph", "forward paragraph",
                "previous line", "next line", "forward line",
                "the previous sentence", "the next sentence",
                "the previous paragraph", "the next paragraph",
                "the previous line", "the next line",
            ]
            if blocked.contains(low) { continue }
            if low.hasPrefix("start of ") || low.hasPrefix("end of ")
                || low.hasPrefix("beginning of ") || low.hasPrefix("top of ")
                || low.hasPrefix("bottom of ")
                || low.hasPrefix("previous ") || low.hasPrefix("next ")
                || low.hasPrefix("forward ") || low.hasPrefix("prior ")
                || low.hasPrefix("the previous ") || low.hasPrefix("the next ") {
                continue
            }
            return spec.after
                ? .goAfterPhrase(target: target)
                : .goToPhrase(target: target)
        }
        return nil
    }

    /// Counted forms: "delete last two words", "select previous 3 sentences", etc.
    /// Requires N ≥ 2 for multi-unit peels (single stays uncounted case).
    /// Voice Control / SpeechPulse style multi-unit edit.
    private static func matchCounted(_ n: String) -> DictationCommand? {
        // Include "one" for character-level commands; multi-unit peels still require N≥2.
        let num = #"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)"#
        let inRange: (Int) -> Bool = { (2...20).contains($0) }
        let specs: [(pattern: String, make: (Int) -> DictationCommand?)] = [
            // Dragon "scratch that N times" / "undo that N times" (N ≥ 2).
            // Bare "scratch that" stays matchExact (count 1).
            (
                #"^(?:scratch|scrap|undo|correct|fix)(?: that| it)? "# + num + #" times?$"#,
                { c in inRange(c) ? .scratchThat(count: c) : nil }
            ),
            (
                #"^(?:scratch|scrap|undo|correct|fix) "# + num + #" times?$"#,
                { c in inRange(c) ? .scratchThat(count: c) : nil }
            ),
            // Dragon "redo that N times" (N ≥ 2). Bare "redo that" is matchExact.
            (
                #"^redo(?: that| it)? "# + num + #" times?$"#,
                { c in inRange(c) ? .redoThat(count: c) : nil }
            ),
            (
                #"^redo "# + num + #" times?$"#,
                { c in inRange(c) ? .redoThat(count: c) : nil }
            ),
            // Dragon "Backspace <n>" / "press backspace N times" (N ≥ 1 including single).
            (
                #"^(?:press |hit )?(?:backspace|delete key) "# + num + #"(?: times?)?$"#,
                { c in (1...100).contains(c) ? .pressBackspace(count: c) : nil }
            ),
            (
                #"^backspace "# + num + #"(?: times?)?$"#,
                { c in (1...100).contains(c) ? .pressBackspace(count: c) : nil }
            ),
            // Forward Delete N (right-of-caret). Do not steal "delete forward character"
            // (deleteNextCharacters) or "delete next N characters".
            (
                #"^(?:press |hit )?forward delete "# + num + #"(?: times?)?$"#,
                { c in (1...100).contains(c) ? .pressForwardDelete(count: c) : nil }
            ),
            (
                #"^(?:press |hit )?delete forward "# + num + #"(?: times?)?$"#,
                { c in (1...100).contains(c) ? .pressForwardDelete(count: c) : nil }
            ),
            // Dragon "Tab <n> times" / "press tab N" (N ≥ 1). Bare "press tab" is exact.
            (
                #"^(?:press |hit )?tab(?: key)? "# + num + #"(?: times?)?$"#,
                { c in (1...20).contains(c) ? .pressTab(count: c) : nil }
            ),
            (
                #"^tab "# + num + #" times?$"#,
                { c in (1...20).contains(c) ? .pressTab(count: c) : nil }
            ),
            // Dragon "press enter N times" / "press return 3" (N ≥ 1).
            // Do not steal mid-utterance "new line" (TextPostProcessor content rewrite).
            (
                #"^(?:press |hit )?(?:enter|return)(?: key)? "# + num + #"(?: times?)?$"#,
                { c in (1...20).contains(c) ? .pressEnter(count: c) : nil }
            ),
            (
                #"^(?:enter|return) "# + num + #" times?$"#,
                { c in (1...20).contains(c) ? .pressEnter(count: c) : nil }
            ),
            // "press space N times" / "space bar 3" (N ≥ 1). Bare "press space" is exact.
            // Do not steal mid-utterance content with bare "space".
            (
                #"^(?:press |hit )?(?:space|spacebar|space bar)(?: key)? "# + num + #"(?: times?)?$"#,
                { c in (1...20).contains(c) ? .pressSpace(count: c) : nil }
            ),
            (
                #"^space "# + num + #" times?$"#,
                { c in (1...20).contains(c) ? .pressSpace(count: c) : nil }
            ),
            // Buffer peel: delete last/previous N words|sentences|paragraphs|lines
            (
                #"^delete (?:the )?(?:last|previous|prior) "# + num + #" words?$"#,
                { c in inRange(c) ? .deleteLastWords(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:last|previous|prior) "# + num + #" sentences?$"#,
                { c in inRange(c) ? .deleteLastSentences(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:last|previous|prior) "# + num + #" paragraphs?$"#,
                { c in inRange(c) ? .deleteLastParagraphs(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:last|previous|prior) "# + num + #" lines?$"#,
                { c in inRange(c) ? .deleteLastLines(count: c) : nil }
            ),
            // Buffer select: last N words (session trailing). Do not steal
            // "select previous N words" (keyboard selectPreviousWords below).
            (
                #"^(?:select|highlight) (?:the )?last "# + num + #" words?$"#,
                { c in inRange(c) ? .selectLastWords(count: c) : nil }
            ),
            // Buffer select: select last/previous N sentences|paragraphs|lines
            (
                #"^select (?:the )?(?:last|previous|prior) "# + num + #" sentences?$"#,
                { c in inRange(c) ? .selectLastSentences(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:last|previous|prior) "# + num + #" paragraphs?$"#,
                { c in inRange(c) ? .selectLastParagraphs(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:last|previous|prior) "# + num + #" lines?$"#,
                { c in inRange(c) ? .selectLastLines(count: c) : nil }
            ),
            // Buffer select: next N sentences|paragraphs|lines (session-relative)
            (
                #"^select (?:the )?(?:next|forward) "# + num + #" sentences?$"#,
                { c in inRange(c) ? .selectNextSentences(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:next|forward) "# + num + #" paragraphs?$"#,
                { c in inRange(c) ? .selectNextParagraphs(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:next|forward) "# + num + #" lines?$"#,
                { c in inRange(c) ? .selectNextLines(count: c) : nil }
            ),
            // Buffer delete: next N sentences|paragraphs|lines
            (
                #"^delete (?:the )?(?:next|forward) "# + num + #" sentences?$"#,
                { c in inRange(c) ? .deleteNextSentences(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:next|forward) "# + num + #" paragraphs?$"#,
                { c in inRange(c) ? .deleteNextParagraphs(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:next|forward) "# + num + #" lines?$"#,
                { c in inRange(c) ? .deleteNextLines(count: c) : nil }
            ),
            // Keyboard: select previous/next N words
            (
                #"^select (?:the )?(?:previous|prior) "# + num + #" words?$"#,
                { c in inRange(c) ? .selectPreviousWords(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:next|forward) "# + num + #" words?$"#,
                { c in inRange(c) ? .selectNextWords(count: c) : nil }
            ),
            // Keyboard: delete next N words only (previous N words = buffer peel above)
            (
                #"^delete (?:the )?(?:next|forward) "# + num + #" words?$"#,
                { c in inRange(c) ? .deleteNextWords(count: c) : nil }
            ),
            // Characters (Voice Control style; N ≥ 1 including single)
            (
                #"^select (?:the )?(?:previous|prior|last) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .selectPreviousCharacters(count: c) : nil }
            ),
            (
                #"^select (?:the )?(?:next|forward) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .selectNextCharacters(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:previous|prior|last) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .deletePreviousCharacters(count: c) : nil }
            ),
            (
                #"^delete (?:the )?(?:next|forward) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .deleteNextCharacters(count: c) : nil }
            ),
            // Cursor move N words (Voice Control style; do not steal bare "move left")
            (
                #"^(?:move )?(?:left|previous|prior|back) "# + num + #" words?$"#,
                { c in (1...20).contains(c) ? .movePreviousWords(count: c) : nil }
            ),
            (
                #"^(?:move )?(?:right|next|forward) "# + num + #" words?$"#,
                { c in (1...20).contains(c) ? .moveNextWords(count: c) : nil }
            ),
            // Cursor move N characters
            (
                #"^(?:move )?(?:left|previous|prior|back) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .movePreviousCharacters(count: c) : nil }
            ),
            (
                #"^(?:move )?(?:right|next|forward) "# + num + #" characters?$"#,
                { c in (1...100).contains(c) ? .moveNextCharacters(count: c) : nil }
            ),
            // Dragon / Voice Control: "move up N lines" / "move down 3 lines"
            // (N ≥ 1 including "one line" spoken with a number). Bare "move up" is exact.
            (
                #"^(?:move )?up "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .moveUpLines(count: c) : nil }
            ),
            (
                #"^(?:move )?down "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .moveDownLines(count: c) : nil }
            ),
            (
                #"^up "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .moveUpLines(count: c) : nil }
            ),
            (
                #"^down "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .moveDownLines(count: c) : nil }
            ),
            // Keyboard select up/down N lines (⇧↑/↓). Do not steal buffer peels:
            // "select last/previous N lines" / "select next N lines".
            (
                #"^select (?:the )?up "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .selectUpLines(count: c) : nil }
            ),
            (
                #"^select (?:the )?down "# + num + #" lines?$"#,
                { c in (1...20).contains(c) ? .selectDownLines(count: c) : nil }
            ),
            // Page scroll N times (Page Up/Down × N). Bare "page up" is exact.
            (
                #"^(?:scroll )?page up "# + num + #"(?: times?| pages?)?$"#,
                { c in (1...20).contains(c) ? .pageUp(count: c) : nil }
            ),
            (
                #"^(?:scroll )?page down "# + num + #"(?: times?| pages?)?$"#,
                { c in (1...20).contains(c) ? .pageDown(count: c) : nil }
            ),
            (
                #"^scroll up "# + num + #"(?: times?| pages?)?$"#,
                { c in (1...20).contains(c) ? .pageUp(count: c) : nil }
            ),
            (
                #"^scroll down "# + num + #"(?: times?| pages?)?$"#,
                { c in (1...20).contains(c) ? .pageDown(count: c) : nil }
            ),
            (
                #"^page up "# + num + #" pages?$"#,
                { c in (1...20).contains(c) ? .pageUp(count: c) : nil }
            ),
            (
                #"^page down "# + num + #" pages?$"#,
                { c in (1...20).contains(c) ? .pageDown(count: c) : nil }
            ),
            // Dragon "move up/down N paragraphs" (N ≥ 1). Bare progressive
            // "previous paragraph" stays matchExact (session cursor).
            (
                #"^(?:move )?up "# + num + #" paragraphs?$"#,
                { c in (1...20).contains(c) ? .moveUpParagraphs(count: c) : nil }
            ),
            (
                #"^(?:move )?down "# + num + #" paragraphs?$"#,
                { c in (1...20).contains(c) ? .moveDownParagraphs(count: c) : nil }
            ),
            // Dragon-style "move up/down N sentences" (N ≥ 1). Progressive
            // "previous sentence" stays matchExact (session cursor).
            (
                #"^(?:move )?up "# + num + #" sentences?$"#,
                { c in (1...20).contains(c) ? .moveUpSentences(count: c) : nil }
            ),
            (
                #"^(?:move )?down "# + num + #" sentences?$"#,
                { c in (1...20).contains(c) ? .moveDownSentences(count: c) : nil }
            ),
            // Select up/down N paragraphs from caret (not buffer last/next peels).
            (
                #"^select (?:the )?up "# + num + #" paragraphs?$"#,
                { c in (1...20).contains(c) ? .selectUpParagraphs(count: c) : nil }
            ),
            (
                #"^select (?:the )?down "# + num + #" paragraphs?$"#,
                { c in (1...20).contains(c) ? .selectDownParagraphs(count: c) : nil }
            ),
            // Select up/down N sentences from caret (not buffer last/next peels).
            (
                #"^select (?:the )?up "# + num + #" sentences?$"#,
                { c in (1...20).contains(c) ? .selectUpSentences(count: c) : nil }
            ),
            (
                #"^select (?:the )?down "# + num + #" sentences?$"#,
                { c in (1...20).contains(c) ? .selectDownSentences(count: c) : nil }
            ),
        ]

        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: n),
                  let count = parseCountToken(String(n[numRange])),
                  let cmd = spec.make(count) else {
                continue
            }
            return cmd
        }
        return nil
    }

    private static func parseCountToken(_ raw: String) -> Int? {
        if let d = Int(raw) { return d }
        let words: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
        ]
        return words[raw]
    }

    /// Build match candidates: raw normalize, then strip politeness fillers.
    private static func normalizeCandidates(_ text: String) -> [String] {
        var n = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Strip trailing sentence punctuation from ASR
        while let last = n.last, ".!?,".contains(last) {
            n.removeLast()
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Collapse internal whitespace
        n = n.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        var out: [String] = []
        if !n.isEmpty { out.append(n) }

        let stripped = stripPoliteness(n)
        if stripped != n, !stripped.isEmpty {
            out.append(stripped)
        }
        return out
    }

    /// Drop leading/trailing politeness that ASR often glues onto commands.
    private static func stripPoliteness(_ s: String) -> String {
        var tokens = s.split(separator: " ").map(String.init)
        let fillers: Set<String> = ["please", "now", "thanks", "thank", "you"]
        while let first = tokens.first, fillers.contains(first) {
            tokens.removeFirst()
        }
        // "thank you" already handled token-wise; drop trailing fillers
        while let last = tokens.last, fillers.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static func matchExact(_ n: String) -> DictationCommand? {
        switch n {
        case "scratch that", "delete that", "undo that",
             "scratch it", "delete it", "undo it",
             "scrap that", // common mis-hear of "scratch"
             "scratch hat", // ASR near-miss
             "go back", "go back that",
             // Immediate undo synonyms
             "correct that", "fix that",
             "correct it", "fix it":
            return .scratchThat(count: 1)
        // Dragon "scratch that twice" (no numeric token; count fixed at 2)
        case "scratch that twice", "scratch it twice", "scrap that twice",
             "undo that twice", "undo it twice",
             "correct that twice", "fix that twice",
             "scratch twice", "undo twice":
            return .scratchThat(count: 2)
        // On-demand AI cleanup — not undo ("fix that" above is scratch).
        case "clean that up", "clean that", "cleanup that", "clean up that",
             "ai cleanup", "ai clean up", "ai clean that",
             "polish that", "polish it", "polish that up",
             "clean this up", "cleanup this":
            return .aiCleanup
        case "replace that", "replace it", "replace last",
             "swap that", "change that":
            return .replaceThat
        case "delete last word", "scratch last word", "scratch word",
             "delete word", "undo word",
             "delete the last word", "scratch the last word",
             "delete last", "scratch last",
             "remove last word", "remove the last word":
            return .deleteLastWord
        // Delete sentence/paragraph/line — listed after delete last word so
        // "delete last word" is not stolen. Do not match "delete that".
        case "delete last sentence", "delete previous sentence", "delete sentence",
             "remove last sentence", "remove previous sentence", "remove sentence":
            return .deleteLastSentence
        case "delete first sentence", "delete the first sentence",
             "remove first sentence", "remove the first sentence",
             "delete 1st sentence", "delete the 1st sentence":
            return .deleteFirstSentence
        // Do not steal "delete last sentence" / "delete previous sentence".
        case "delete next sentence", "delete forward sentence",
             "remove next sentence", "remove forward sentence":
            return .deleteNextSentence
        case "delete last paragraph", "delete previous paragraph", "delete paragraph",
             "remove last paragraph", "remove previous paragraph", "remove paragraph":
            return .deleteLastParagraph
        case "delete first paragraph", "delete the first paragraph",
             "remove first paragraph", "remove the first paragraph",
             "delete 1st paragraph", "delete the 1st paragraph":
            return .deleteFirstParagraph
        // Do not steal "delete last paragraph" / "delete previous paragraph".
        case "delete next paragraph", "delete forward paragraph",
             "remove next paragraph", "remove forward paragraph":
            return .deleteNextParagraph
        case "delete last line", "delete previous line", "delete line",
             "remove last line", "remove previous line", "remove line":
            return .deleteLastLine
        case "delete first line", "delete the first line",
             "remove first line", "remove the first line",
             "delete 1st line", "delete the 1st line":
            return .deleteFirstLine
        // Do not steal "delete last line" / "delete previous line".
        case "delete next line", "delete forward line",
             "remove next line", "remove forward line":
            return .deleteNextLine
        case "clear all", "delete all", "scratch all", "clear everything",
             "start over", "delete everything", "clear it all",
             "wipe all", "wipe everything":
            return .clearAll
        case "press enter", "press return", "hit enter", "hit return",
             "press return key", "press the enter key", "hit the enter key",
             "enter key", "return key":
            return .pressEnter(count: 1)
        case "press enter twice", "press return twice", "hit enter twice",
             "hit return twice", "enter twice", "return twice":
            return .pressEnter(count: 2)
        case "press tab", "hit tab", "press tab key", "press the tab key",
             "tab key":
            return .pressTab(count: 1)
        case "tab twice", "press tab twice", "hit tab twice", "tab key twice":
            return .pressTab(count: 2)
        // Explicit press/hit only — bare "space bar" is content ITN → " ".
        case "press space", "hit space", "press space bar", "hit space bar",
             "press spacebar", "hit spacebar", "space key", "press space key",
             "hit space key":
            return .pressSpace(count: 1)
        case "press space twice", "hit space twice", "space twice",
             "press space bar twice", "space bar twice", "spacekey twice":
            return .pressSpace(count: 2)
        // Keyboard backspace only — do not match "delete that" / "delete it"
        // (those remain scratchThat) or "delete last" (deleteLastWord).
        // Forward delete phrases are matched separately below.
        case "press backspace", "hit backspace", "backspace",
             "press delete", "hit delete", "delete key":
            return .pressBackspace(count: 1)
        case "backspace twice", "press backspace twice", "hit backspace twice":
            return .pressBackspace(count: 2)
        // Single character (also covered by counted forms with "one")
        case "delete previous character", "delete last character",
             "delete prior character", "remove previous character",
             "remove last character":
            return .deletePreviousCharacters(count: 1)
        case "delete next character", "delete forward character",
             "remove next character", "remove forward character":
            return .deleteNextCharacters(count: 1)
        // Forward Delete (0x75) — not laptop Delete/Backspace.
        case "forward delete", "press forward delete",
             "delete forward", "press delete forward":
            return .pressForwardDelete(count: 1)
        case "forward delete twice", "press forward delete twice",
             "delete forward twice", "press delete forward twice":
            return .pressForwardDelete(count: 2)
        // Bare single character select (counted forms need a number token).
        case "select previous character", "select last character",
             "select prior character", "highlight previous character",
             "highlight last character":
            return .selectPreviousCharacters(count: 1)
        case "select next character", "select forward character",
             "highlight next character", "highlight forward character":
            return .selectNextCharacters(count: 1)
        // Escape requires press/hit/key — bare "escape" is not a command.
        case "press escape", "press esc", "hit escape", "hit esc",
             "escape key", "esc key", "press the escape key", "hit the escape key":
            return .pressEscape
        // System ⌘Z — do not steal "undo that" / "scratch that" / "correct that".
        case "system undo", "press undo", "undo key", "app undo", "command undo":
            return .pressUndo
        // System ⌘⇧Z — do not steal "redo that" (EditStack redo).
        case "system redo", "press redo", "redo key", "app redo", "command redo":
            return .pressRedo
        case "insert date", "insert today's date", "today's date", "insert the date",
             "insert todays date", "todays date":
            return .insertDate
        case "insert time", "insert the time", "current time":
            return .insertTime
        case "copy that", "copy all", "copy it", "copy this", "copy the text":
            return .copyThat
        case "paste that", "paste it", "paste this", "paste here":
            return .pasteThat
        case "duplicate that", "duplicate it", "dupe that", "copy paste that",
             "repeat that", "repeat it", "say that again", "again that":
            return .duplicateThat
        case "redo that", "redo it", "restore that", "undo undo",
             "redo last", "put it back":
            return .redoThat(count: 1)
        case "redo that twice", "redo it twice", "redo twice", "restore that twice":
            return .redoThat(count: 2)
        // Sticky caps modes (Dragon-style)
        case "no caps on", "no caps mode":
            return .setCapsMode(.noCaps)
        case "all caps on", "all caps mode", "all caps":
            return .setCapsMode(.allCaps)
        case "caps on", "cap on", "title case on":
            return .setCapsMode(.capsOn)
        case "caps off", "cap off", "no caps off", "all caps off",
             "normal caps", "normal case", "default caps":
            return .setCapsMode(.normal)
        // Sticky spell mode (Dragon / Mac-style letter packing)
        // Off phrases listed before bare "spell mode" so exact match wins.
        case "spell mode off", "spell off", "end spell", "end spelling",
             "dictation mode":
            return .setSpellMode(.off)
        case "spell mode", "spelling mode", "start spelling", "spell on":
            return .setSpellMode(.on)
        // Select last phrase + enter spell mode (does not delete text)
        case "spell that", "spell it", "spell last":
            return .spellThat
        // One-shot last-word transforms
        case "cap that", "capitalize that", "caps that", "capital that":
            return .capThat
        // One-shot next-word arm (do not steal "cap that" / "caps on")
        case "cap next", "capitalize next", "caps next", "capital next":
            return .capNext
        case "all caps that", "uppercase that", "upper case that":
            return .allCapsThat
        case "no caps that", "lowercase that", "lower case that":
            return .noCapsThat
        case "title case that", "title case that phrase", "titlecase that",
             "title case phrase":
            return .titleCaseThat
        case "sentence case that", "sentence case that phrase",
             "sentencecase that":
            return .sentenceCaseThat
        case "no space that", "nospace that", "no spaces that",
             "delete the space", "remove the space":
            return .noSpaceThat
        // Sticky no-space mode (segment glue only; not letter packing)
        // Off phrases listed before bare "no space on" so exact match wins.
        // "no space that" is one-shot above — does not steal sticky phrases.
        case "no space off", "no spaces off", "compound off", "spaces on":
            return .setNoSpaceMode(.off)
        case "no space on", "no spaces on", "compound on":
            return .setNoSpaceMode(.on)
        case "select that", "select it", "select last", "highlight that",
             "highlight it", "highlight last":
            return .selectThat
        case "select last word", "highlight last word",
             "select the last word", "highlight the last word":
            return .selectLastWord
        // Keyboard select word — do not steal "select last word" or bare "next word".
        case "select next word", "select forward word",
             "highlight next word", "highlight forward word":
            return .selectNextWord
        case "select previous word", "select prior word",
             "highlight previous word", "highlight prior word":
            return .selectPreviousWord
        // Keyboard delete next word — do not steal "delete last word" / "delete word".
        case "delete next word", "delete forward word",
             "remove next word", "remove forward word":
            return .deleteNextWord
        // Keyboard delete previous word — do not steal "delete last word" / "delete previous sentence".
        case "delete previous word", "delete prior word",
             "remove previous word", "remove prior word":
            return .deletePreviousWord
        case "select last sentence", "select sentence",
             "highlight last sentence", "highlight sentence":
            return .selectLastSentence
        // Progressive previous — from end lands on last; further steps walk back.
        case "select previous sentence", "select prior sentence",
             "highlight previous sentence", "highlight prior sentence":
            return .selectPreviousSentence
        // "first" → "1st" via SpokenNumberITN before parse; match both.
        case "select first sentence", "select the first sentence",
             "select 1st sentence", "select the 1st sentence",
             "highlight first sentence", "highlight the first sentence",
             "highlight 1st sentence", "highlight the 1st sentence":
            return .selectFirstSentence
        // Session-relative next sentence — do not steal "next sentence" (move) or "select last".
        case "select next sentence", "select forward sentence",
             "highlight next sentence", "highlight forward sentence":
            return .selectNextSentence
        case "select last paragraph", "select paragraph",
             "highlight last paragraph", "highlight paragraph":
            return .selectLastParagraph
        case "select previous paragraph", "select prior paragraph",
             "highlight previous paragraph", "highlight prior paragraph":
            return .selectPreviousParagraph
        // "first" → "1st" via SpokenNumberITN before parse; match both.
        case "select first paragraph", "select the first paragraph",
             "select 1st paragraph", "select the 1st paragraph",
             "highlight first paragraph", "highlight the first paragraph",
             "highlight 1st paragraph", "highlight the 1st paragraph":
            return .selectFirstParagraph
        // Session-relative next paragraph — do not steal "select last paragraph".
        case "select next paragraph", "select forward paragraph",
             "highlight next paragraph", "highlight forward paragraph":
            return .selectNextParagraph
        // Select line — listed before move "previous line" so select wins on
        // full phrases; bare "previous line" is moveUpLine only.
        case "select last line", "select line", "select this line",
             "highlight last line", "highlight line", "highlight this line":
            return .selectLastLine
        case "select previous line", "select prior line",
             "highlight previous line", "highlight prior line":
            return .selectPreviousLine
        // "first" → "1st" via SpokenNumberITN before parse; match both.
        case "select first line", "select the first line",
             "select 1st line", "select the 1st line",
             "highlight first line", "highlight the first line",
             "highlight 1st line", "highlight the 1st line":
            return .selectFirstLine
        // Session-relative next line — do not steal "select last line" / "select line".
        case "select next line", "select forward line",
             "highlight next line", "highlight forward line":
            return .selectNextLine
        case "select all", "highlight all", "select everything":
            return .selectAll
        case "unselect that", "unselect", "deselect that", "clear selection",
             "deselect":
            return .unselectThat
        case "bold that", "bold it", "make that bold", "make it bold":
            return .boldThat
        case "italic that", "italicize that", "italics that",
             "italic it", "make that italic", "make it italic":
            return .italicThat
        case "underline that", "underline it", "make that underlined":
            return .underlineThat
        case "cut that", "cut it", "cut selection":
            return .cutThat
        case "move left", "left word", "previous word", "go left",
             "back one word":
            return .moveLeftWord
        case "move right", "right word", "next word", "go right",
             "forward one word":
            return .moveRightWord
        // Host arrow line moves (↑/↓). Progressive "next/previous line" is below
        // (aligned with next/previous sentence). Do not match "select previous line".
        // Counted "move up N lines" is matchCounted.
        case "move up", "up a line", "go up", "line up":
            return .moveUpLines(count: 1)
        case "move down", "down a line", "go down", "line down":
            return .moveDownLines(count: 1)
        // Keyboard select one line up/down (⇧↑/↓). Not buffer "select previous line".
        case "select up a line", "select up line", "select line up":
            return .selectUpLines(count: 1)
        case "select down a line", "select down line", "select line down":
            return .selectDownLines(count: 1)
        // Document edges before line edges so "… of document" phrases win as full matches
        // (exact match; line phrases stay separate strings).
        case "beginning of document", "top of document", "go to top of document",
             "start of document", "go to beginning of document":
            return .moveToDocumentStart
        case "end of document", "bottom of document",
             "go to end of document", "go to bottom of document":
            return .moveToDocumentEnd
        case "go to start", "go to beginning", "beginning of line":
            return .moveToStart
        case "go to end", "end of line":
            return .moveToEnd
        // Sentence / paragraph edges (Dragon Medical-style) — before progressive
        // previous/next so "start of sentence" is not stolen by "previous sentence".
        case "start of sentence", "beginning of sentence",
             "go to start of sentence", "go to beginning of sentence",
             "move to start of sentence", "move to beginning of sentence":
            return .moveToSentenceStart
        case "end of sentence", "go to end of sentence",
             "move to end of sentence":
            return .moveToSentenceEnd
        case "start of paragraph", "beginning of paragraph",
             "go to start of paragraph", "go to beginning of paragraph",
             "move to start of paragraph", "move to beginning of paragraph":
            return .moveToParagraphStart
        case "end of paragraph", "go to end of paragraph",
             "move to end of paragraph":
            return .moveToParagraphEnd
        // Page scroll — exact phrases; "move up" / "go up" remain moveUpLine.
        // Counted "page down N times" is matchCounted.
        case "page up", "scroll up", "scroll page up":
            return .pageUp(count: 1)
        case "page down", "scroll down", "scroll page down":
            return .pageDown(count: 1)
        case "page up twice", "scroll up twice", "scroll page up twice":
            return .pageUp(count: 2)
        case "page down twice", "scroll down twice", "scroll page down twice":
            return .pageDown(count: 2)
        // Progressive line move — dual LineCursor.tla (like next/previous sentence).
        // Do not steal "select next line" / "delete next line" (exact match elsewhere).
        case "go to previous line", "previous line",
             "move to previous line", "back a line":
            return .moveToPreviousLine
        case "go to next line", "next line",
             "move to next line", "forward a line":
            return .moveToNextLine
        // Navigation — do not match "select previous sentence" (selectLastSentence).
        case "go to previous sentence", "previous sentence",
             "move to previous sentence", "back a sentence":
            return .moveToPreviousSentence
        case "go to next sentence", "next sentence",
             "move to next sentence", "forward a sentence":
            return .moveToNextSentence
        // Paragraph move — do not steal "select previous/next paragraph".
        // Progressive session cursor (ParagraphCursor.tla).
        case "go to previous paragraph", "previous paragraph",
             "move to previous paragraph", "back a paragraph":
            return .moveToPreviousParagraph
        case "go to next paragraph", "next paragraph",
             "move to next paragraph", "forward a paragraph":
            return .moveToNextParagraph
        // Dragon counted host-style paragraph jumps (session dual).
        // "move up a paragraph" ≠ progressive "previous paragraph".
        case "move up a paragraph", "up a paragraph", "move up paragraph":
            return .moveUpParagraphs(count: 1)
        case "move down a paragraph", "down a paragraph", "move down paragraph":
            return .moveDownParagraphs(count: 1)
        // Counted host-style sentence jumps (session dual).
        // "move up a sentence" ≠ progressive "previous sentence".
        case "move up a sentence", "up a sentence", "move up sentence":
            return .moveUpSentences(count: 1)
        case "move down a sentence", "down a sentence", "move down sentence":
            return .moveDownSentences(count: 1)
        // Select one paragraph up/down from caret (not progressive select previous).
        case "select up a paragraph", "select up paragraph", "select paragraph up":
            return .selectUpParagraphs(count: 1)
        case "select down a paragraph", "select down paragraph", "select paragraph down":
            return .selectDownParagraphs(count: 1)
        // Select one sentence up/down from caret (not progressive select previous).
        case "select up a sentence", "select up sentence", "select sentence up":
            return .selectUpSentences(count: 1)
        case "select down a sentence", "select down sentence", "select sentence down":
            return .selectDownSentences(count: 1)
        default:
            return nil
        }
    }

    var isCommand: Bool { self != .none }

    /// User-facing command catalog for Settings / help (say → effect).
    static let helpCatalog: [(say: String, effect: String)] = [
        ("scratch that / correct that", "Undo last phrase (multi-level)"),
        ("scratch that two times / undo that 3 times", "Undo last N phrases in one go"),
        ("redo that two times / redo that twice", "Redo last N scratched phrases"),
        ("backspace 5 / press backspace three times", "Press Backspace N times (keyboard only)"),
        ("clean that up / ai cleanup / polish that", "AI cleanup selection or last phrase (also hold+C)"),
        ("replace that", "Next phrase replaces last (multi-step)"),
        ("replace X with Y / change X to Y / swap X for Y", "Replace last occurrence of X with Y"),
        ("delete X / remove X", "Delete last occurrence of phrase X"),
        ("select X / highlight X", "Select last occurrence of phrase X (type-over next)"),
        ("go to X / move to X / insert before X", "Move caret to start of last occurrence of X"),
        ("go after X / move after X / insert after X", "Move caret to end of last occurrence of X"),
        ("resume with X / continue with X", "Keep through X, delete after, continue dictating"),
        ("redo that", "Restore last scratched phrase"),
        ("delete last word", "Remove last word"),
        ("delete last two words / delete previous 3 words", "Remove last N words"),
        ("delete previous word / delete prior word", "Delete previous word (⇧⌥← then ⌫; keyboard only)"),
        ("delete last sentence / previous sentence", "Remove last sentence"),
        ("delete first sentence", "Remove first sentence"),
        ("delete next sentence / delete forward sentence", "Remove second sentence (session-relative)"),
        ("delete last paragraph / previous paragraph", "Remove last paragraph"),
        ("delete first paragraph", "Remove first paragraph"),
        ("delete next paragraph / delete forward paragraph", "Remove next paragraph (progressive)"),
        ("delete last line / delete line", "Remove last line"),
        ("delete first line", "Remove first line"),
        ("delete next line / delete forward line", "Remove next line (progressive)"),
        ("clear all", "Wipe session text"),
        ("press enter / press return", "Insert Return once"),
        ("press enter N times / enter twice", "Insert Return N times"),
        ("press tab / tab key", "Insert Tab once"),
        ("tab N times / press tab 3 times", "Insert Tab N times"),
        ("press space / hit space", "Insert Space once"),
        ("press space N times / space twice", "Insert Space N times"),
        ("press backspace / delete key", "Press Backspace once (keyboard only)"),
        ("backspace N / press backspace N times", "Press Backspace N times (keyboard only)"),
        ("forward delete / delete forward", "Press Forward Delete once (keyboard only; not Backspace)"),
        ("forward delete N / delete forward 3 times", "Press Forward Delete N times (keyboard only)"),
        ("select previous character / select next character", "Select one character left/right (keyboard)"),
        ("press escape / escape key", "Press Escape once (keyboard only; does not cancel)"),
        ("system undo / press undo / undo key", "System undo (⌘Z; keyboard only; not scratch that)"),
        ("system redo / press redo / redo key", "System redo (⌘⇧Z; keyboard only; not redo that)"),
        ("insert date / today's date", "Type today's date (e.g. July 10, 2026)"),
        ("insert time / current time", "Type current time (e.g. 3:45 p.m.)"),
        ("copy that", "Copy session to clipboard"),
        ("paste that", "Paste clipboard (⌘V)"),
        ("duplicate that / repeat that / dupe that", "Copy last phrase and paste again"),
        ("caps on / all caps on / no caps on", "Sticky capitalization mode"),
        ("caps off", "Back to normal casing"),
        ("spell mode / start spelling", "Sticky spell mode (letter packing)"),
        ("spell off / end spelling / dictation mode", "Exit spell mode"),
        ("spell that", "Select last phrase + enter spell mode"),
        ("spell as a b c", "Pack letters once (no sticky mode)"),
        ("cap that / all caps that", "Transform last word"),
        ("cap next / capitalize next", "Capitalize first word of next phrase"),
        ("title case that", "Title-case last phrase"),
        ("sentence case that", "Sentence-case last phrase"),
        ("no space that", "Join last word without space"),
        ("no space on / compound on", "Sticky no-space mode (glue segments)"),
        ("no space off / compound off / spaces on", "Exit no-space mode"),
        ("select that", "Select last phrase"),
        ("select last word", "Select last word"),
        ("select last two words / select last 3 words", "Select last N words"),
        ("select next word / select forward word", "Select word at/after caret + arm type-over"),
        ("select previous word / select prior word", "Select trailing word + arm type-over"),
        ("select previous N words", "Select trailing N words + arm type-over"),
        ("delete next word / delete forward word", "Delete next word (⇧⌥→ then ⌫; keyboard only)"),
        ("select last sentence", "Select last sentence"),
        ("select previous sentence / select prior sentence", "Select previous sentence (progressive)"),
        ("select first sentence / the first sentence", "Select first sentence"),
        ("select next sentence / select forward sentence", "Select next sentence (progressive)"),
        ("select last paragraph", "Select last paragraph"),
        ("select previous paragraph / select prior paragraph", "Select previous paragraph (progressive)"),
        ("select first paragraph / the first paragraph", "Select first paragraph"),
        ("select next paragraph / select forward paragraph", "Select next paragraph (progressive)"),
        ("next paragraph / go to next paragraph", "Move to next paragraph start (progressive)"),
        ("previous paragraph / go to previous paragraph", "Move to previous paragraph start (progressive)"),
        ("select last line / select line", "Select last line"),
        ("select previous line / select prior line", "Select previous line (progressive)"),
        ("select first line / the first line", "Select first line"),
        ("select next line / select forward line", "Select next line (progressive)"),
        ("select previous two words / select next 3 words", "Select N words (keyboard)"),
        ("delete previous N characters / select previous N characters", "Character-level edit (Voice Control style)"),
        ("delete last two sentences / paragraphs / lines", "Remove last N sentences/paragraphs/lines"),
        ("delete next two sentences / paragraphs / lines", "Remove next N sentences/paragraphs/lines"),
        ("select last two sentences / previous 3 paragraphs", "Select last N sentences/paragraphs/lines"),
        ("select next two sentences / paragraphs / lines", "Select next N sentences/paragraphs/lines"),
        ("select all", "Select all (⌘A)"),
        ("unselect that / deselect", "Collapse selection (caret to end)"),
        ("bold that", "Select last phrase + bold (⌘B), then unselect"),
        ("italic that", "Select last phrase + italic (⌘I), then unselect"),
        ("underline that", "Select last phrase + underline (⌘U), then unselect"),
        ("cut that", "Select last phrase + cut (⌘X)"),
        ("move left / previous word", "Cursor left one word (⌥←)"),
        ("move right / next word", "Cursor right one word (⌥→)"),
        ("move up / move down / line up / line down", "Cursor up/down one line (host ↑↓)"),
        ("move up N lines / move down 3 lines", "Cursor up/down N lines (host ↑↓ × N)"),
        ("move up N paragraphs / move down 3 paragraphs", "Jump N paragraphs (session dual)"),
        ("move up N sentences / move down 3 sentences", "Jump N sentences (session dual)"),
        ("select up N paragraphs / select down 2 paragraphs", "Select N paragraphs from caret"),
        ("select up N sentences / select down 2 sentences", "Select N sentences from caret"),
        ("select up N lines / select down 3 lines", "Select N lines up/down (⇧↑/↓; keyboard only)"),
        ("next line / previous line", "Progressive line start (session dual)"),
        ("go to start / beginning of line", "Cursor to line start (⌘←)"),
        ("go to end / end of line", "Cursor to line end (⌘→)"),
        ("start of sentence / end of sentence", "Caret to sentence edge under cursor"),
        ("start of paragraph / end of paragraph", "Caret to paragraph edge under cursor"),
        ("beginning of document / top of document", "Cursor to document start (⌘↑)"),
        ("end of document / bottom of document", "Cursor to document end (⌘↓)"),
        ("page up / scroll up", "Page up once (Page Up key)"),
        ("page down / scroll down", "Page down once (Page Down key)"),
        ("page down N times / scroll up 3 pages", "Page Up/Down × N"),
        ("previous sentence / go to previous sentence", "Cursor to start of last sentence (← × n)"),
        ("next sentence / go to next sentence", "Cursor to start of second sentence (session-relative)"),
        ("period / comma / …", "Spoken punctuation"),
        ("new line / new paragraph", "Line breaks"),
        ("bullet point / next bullet", "Bulleted list item"),
        ("number one / next number", "Numbered list item"),
        ("end list / stop numbering", "Reset list counter"),
        ("dot com / at sign", "Domain & email bits"),
        ("hashtag X / at sign X / mention X", "Social #tag and @handle"),
        ("www / https colon slash slash", "Spoken URL bits"),
        ("tilde slash / home slash / dot slash / slash / dot dot slash",
         "Path prefixes (~/ ./ / ../)"),
    ]
}

// MARK: - Transcript selection bounds (pure)

/// Pure helpers for spoken select-first/last sentence / paragraph.
/// Substrings feed `selectBackward` / `selectForward` via `String.count`.
enum TranscriptSelection {
    /// Character-offset range of one sentence (end exclusive).
    /// Starts at sentence content (skips separator whitespace after prior punct).
    struct SentenceRange: Equatable {
        let start: Int
        let end: Int
    }

    /// Trailing N whitespace-delimited words (session buffer style).
    /// Includes the space before the first selected word (matches select-last-word).
    /// Clamps when N exceeds word count. Empty when count < 1 or text empty.
    static func lastWords(_ text: String, count: Int) -> String {
        guard count > 0, !text.isEmpty else { return "" }
        var remaining = text
        for _ in 0..<count {
            while remaining.last?.isWhitespace == true {
                remaining.removeLast()
            }
            guard !remaining.isEmpty else { break }
            if let lastSpace = remaining.lastIndex(where: { $0.isWhitespace }) {
                var start = remaining.index(after: lastSpace)
                if start > remaining.startIndex {
                    let before = remaining.index(before: start)
                    if remaining[before].isWhitespace {
                        start = before
                    }
                }
                remaining = String(remaining[..<start])
            } else {
                remaining = ""
                break
            }
        }
        let remove = text.count - remaining.count
        guard remove > 0 else { return "" }
        return String(text.suffix(remove))
    }

    /// Whitespace-delimited word ranges (content only; no leading space).
    /// Empty text → `[]`. Dual of select-next-word progressive arm.
    static func wordRanges(_ text: String) -> [SentenceRange] {
        guard !text.isEmpty else { return [] }
        var ranges: [SentenceRange] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex && text[i].isWhitespace {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            let start = text.distance(from: text.startIndex, to: i)
            while i < text.endIndex && !text[i].isWhitespace {
                i = text.index(after: i)
            }
            let end = text.distance(from: text.startIndex, to: i)
            ranges.append(SentenceRange(start: start, end: end))
        }
        return ranges
    }

    /// Word span for "select next N words" from `caret` (nil = end → no next).
    /// Picks the first word whose end is after caret (covers start-of-word and mid-word),
    /// then extends through N words. Content-only (no leading space).
    static func nextWordsRange(
        _ text: String,
        caret: Int?,
        count: Int
    ) -> SentenceRange? {
        guard count > 0 else { return nil }
        let pos = min(max(caret ?? text.count, 0), text.count)
        guard pos < text.count else { return nil }
        let words = wordRanges(text)
        guard let startIdx = words.firstIndex(where: { $0.end > pos }) else {
            return nil
        }
        let endIdx = min(startIdx + count - 1, words.count - 1)
        return SentenceRange(start: words[startIdx].start, end: words[endIdx].end)
    }

    /// Session caret after moving N characters left or right.
    /// `caret == nil` means end of buffer. Result clamped to `0...text.count`.
    /// Dual of AppState.performMoveCharacters + sessionCaret (CharacterCaret.tla).
    static func offsetAfterCharacterMove(
        _ text: String,
        caret: Int?,
        left: Bool,
        count: Int
    ) -> Int {
        let len = text.count
        var pos = min(max(caret ?? len, 0), len)
        guard count > 0 else { return pos }
        if left {
            pos = max(0, pos - count)
        } else {
            pos = min(len, pos + count)
        }
        return pos
    }

    /// Session caret after moving N whitespace-delimited words left or right.
    /// `caret == nil` means end of buffer. Result clamped to `0...text.count`.
    /// Dual of AppState.performMoveWord(s) + sessionCaret (WordCaret.tla).
    static func offsetAfterWordMove(
        _ text: String,
        caret: Int?,
        left: Bool,
        count: Int
    ) -> Int {
        guard count > 0 else {
            return min(max(caret ?? text.count, 0), text.count)
        }
        var pos = min(max(caret ?? text.count, 0), text.count)
        for _ in 0..<count {
            if left {
                // Skip whitespace immediately before caret
                while pos > 0 {
                    let i = text.index(text.startIndex, offsetBy: pos - 1)
                    if text[i].isWhitespace { pos -= 1 } else { break }
                }
                // Skip word characters
                while pos > 0 {
                    let i = text.index(text.startIndex, offsetBy: pos - 1)
                    if text[i].isWhitespace { break }
                    pos -= 1
                }
            } else {
                // Skip word characters at/after caret
                while pos < text.count {
                    let i = text.index(text.startIndex, offsetBy: pos)
                    if text[i].isWhitespace { break }
                    pos += 1
                }
                // Skip following whitespace → land at next word start or end
                while pos < text.count {
                    let i = text.index(text.startIndex, offsetBy: pos)
                    if !text[i].isWhitespace { break }
                    pos += 1
                }
            }
        }
        return pos
    }

    /// All sentence ranges in `text`, split on `[.?!]\s+` (punct stays with prior sentence).
    /// Single sentence / no separator → one range `0..<count`. Empty → `[]`.
    static func sentenceRanges(_ text: String) -> [SentenceRange] {
        guard !text.isEmpty else { return [] }
        let pattern = try! NSRegularExpression(pattern: #"[.?!]\s+"#)
        var ranges: [SentenceRange] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            let searchNS = NSRange(searchStart..., in: text)
            if let match = pattern.firstMatch(in: text, range: searchNS),
               let matchRange = Range(match.range, in: text) {
                // Include punct only (match is punct + whitespace).
                let afterPunct = text.index(after: matchRange.lowerBound)
                let start = text.distance(from: text.startIndex, to: searchStart)
                let end = text.distance(from: text.startIndex, to: afterPunct)
                ranges.append(SentenceRange(start: start, end: end))
                // Next sentence content starts after separator whitespace.
                var next = afterPunct
                while next < text.endIndex && text[next].isWhitespace {
                    next = text.index(after: next)
                }
                if next >= text.endIndex { return ranges }
                searchStart = next
            } else {
                let start = text.distance(from: text.startIndex, to: searchStart)
                ranges.append(SentenceRange(start: start, end: text.count))
                break
            }
        }
        return ranges
    }

    /// Last sentence: segment after final `[.?!]` + whitespace, else whole buffer.
    /// Includes the whitespace after the terminator (matches select-last-word style).
    static func lastSentence(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let pattern = try! NSRegularExpression(pattern: #"[.?!]\s+"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard let last = matches.last, let matchRange = Range(last.range, in: text) else {
            return text
        }
        // Start at first whitespace after punct so selection includes leading space.
        let afterPunct = text.index(after: matchRange.lowerBound)
        return String(text[afterPunct...])
    }

    /// First sentence: segment through first `[.?!]` before whitespace, else whole buffer.
    /// Includes trailing punct; excludes following whitespace.
    static func firstSentence(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let pattern = try! NSRegularExpression(pattern: #"[.?!]\s+"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let first = pattern.firstMatch(in: text, range: range),
              let matchRange = Range(first.range, in: text) else {
            return text
        }
        // Include punct only (match is punct + whitespace; stop after punct).
        let afterPunct = text.index(after: matchRange.lowerBound)
        return String(text[..<afterPunct])
    }

    /// Second sentence: after `firstSentence` + leading whitespace, `firstSentence` of remainder.
    /// Empty if no second sentence. Does not include leading separator whitespace.
    static func secondSentence(_ text: String) -> String {
        let first = firstSentence(text)
        guard !first.isEmpty, first.count < text.count else { return "" }
        let afterFirst = text.index(text.startIndex, offsetBy: first.count)
        let remainder = String(text[afterFirst...].drop(while: { $0.isWhitespace }))
        guard !remainder.isEmpty else { return "" }
        return firstSentence(remainder)
    }

    /// Character offset of second-sentence content start, or nil if none.
    static func secondSentenceStartOffset(_ text: String) -> Int? {
        let first = firstSentence(text)
        guard !first.isEmpty, first.count < text.count else { return nil }
        var idx = text.index(text.startIndex, offsetBy: first.count)
        while idx < text.endIndex && text[idx].isWhitespace {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex else { return nil }
        guard !secondSentence(text).isEmpty else { return nil }
        return text.distance(from: text.startIndex, to: idx)
    }

    /// Last paragraph: segment after final `\n\n` or `\n`, else whole buffer.
    /// Trailing blank paragraph (`…\n\n` / `…\n`) returns the separator so
    /// delete peels it instead of no-op on empty content.
    static func lastParagraph(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let r = text.range(of: "\n\n", options: .backwards) {
            let after = String(text[r.upperBound...])
            return after.isEmpty ? "\n\n" : after
        }
        if let r = text.range(of: "\n", options: .backwards) {
            let after = String(text[r.upperBound...])
            return after.isEmpty ? "\n" : after
        }
        return text
    }

    /// First paragraph: segment before first `\n\n` or `\n`, else whole buffer.
    static func firstParagraph(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let r = text.range(of: "\n\n") {
            return String(text[..<r.lowerBound])
        }
        if let r = text.range(of: "\n") {
            return String(text[..<r.lowerBound])
        }
        return text
    }

    /// Second paragraph: after `firstParagraph` + one `\n\n` or `\n`, `firstParagraph` of remainder.
    /// Empty if no second paragraph.
    static func secondParagraph(_ text: String) -> String {
        let ranges = paragraphRanges(text)
        guard ranges.count >= 2 else { return "" }
        let r = ranges[1]
        let start = text.index(text.startIndex, offsetBy: r.start)
        let end = text.index(text.startIndex, offsetBy: r.end)
        return String(text[start..<end])
    }

    /// Character offset of second-paragraph content start, or nil if none.
    static func secondParagraphStartOffset(_ text: String) -> Int? {
        let ranges = paragraphRanges(text)
        guard ranges.count >= 2 else { return nil }
        return ranges[1].start
    }

    /// All paragraph ranges in `text` (end exclusive).
    /// Splits like `firstParagraph` / recursive remainder: prefer `\n\n`, else `\n`.
    /// Empty → `[]`. Single block → one range `0..<count`.
    static func paragraphRanges(_ text: String) -> [SentenceRange] {
        guard !text.isEmpty else { return [] }
        var ranges: [SentenceRange] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            let remainder = String(text[searchStart...])
            let first = firstParagraph(remainder)
            let start = text.distance(from: text.startIndex, to: searchStart)
            let end = start + first.count
            ranges.append(SentenceRange(start: start, end: end))
            var idx = text.index(searchStart, offsetBy: first.count)
            if idx >= text.endIndex { break }
            if text[idx...].hasPrefix("\n\n") {
                idx = text.index(idx, offsetBy: 2)
            } else if text[idx] == "\n" {
                idx = text.index(after: idx)
            } else {
                break
            }
            if idx >= text.endIndex { break }
            searchStart = idx
        }
        return ranges
    }

    /// Last line: segment after final `\n` (content only, no leading separator).
    /// Whole buffer if no newline. Trailing empty line (`…\n`) returns `"\n"`
    /// so delete peels the newline instead of no-op.
    static func lastLine(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let r = text.range(of: "\n", options: .backwards) {
            let after = String(text[r.upperBound...])
            return after.isEmpty ? "\n" : after
        }
        return text
    }

    /// First line: content before first `\n`, else whole buffer.
    /// Leading newline (`\n…`) returns `""` (empty first line).
    static func firstLine(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let r = text.range(of: "\n") {
            return String(text[..<r.lowerBound])
        }
        return text
    }

    /// All line ranges in `text` (end exclusive of content; caret may sit at `end`).
    /// Split on `\n`. Empty → `[]`.
    static func lineRanges(_ text: String) -> [SentenceRange] {
        guard !text.isEmpty else { return [] }
        var ranges: [SentenceRange] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            if let nl = text.range(of: "\n", range: searchStart..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: searchStart)
                let end = text.distance(from: text.startIndex, to: nl.lowerBound)
                ranges.append(SentenceRange(start: start, end: end))
                searchStart = nl.upperBound
                if searchStart >= text.endIndex {
                    // Trailing newline: empty last line (content length 0)
                    // Not added — delete last peels via lastLine special case.
                    break
                }
            } else {
                let start = text.distance(from: text.startIndex, to: searchStart)
                ranges.append(SentenceRange(start: start, end: text.count))
                break
            }
        }
        return ranges
    }

    /// 0-based unit index for `pos` (caret may sit at range.end). Nil when empty.
    /// Dual of LineCaret / SentenceEdge range-under-caret.
    static func rangeIndexContaining(_ pos: Int, ranges: [SentenceRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let p = max(0, pos)
        for (i, r) in ranges.enumerated() {
            if p >= r.start && p <= r.end { return i }
        }
        // Between units (e.g. on `\n`) → treat as end of previous unit.
        for (i, r) in ranges.enumerated() {
            if i + 1 < ranges.count {
                let next = ranges[i + 1]
                if p > r.end && p < next.start { return i }
            }
        }
        return ranges.count - 1
    }

    /// Alias for line ranges (same grain as `rangeIndexContaining`).
    static func lineIndexContaining(_ pos: Int, ranges: [SentenceRange]) -> Int? {
        rangeIndexContaining(pos, ranges: ranges)
    }

    /// Start of the unit under caret (sentence / paragraph / line ranges).
    /// Dual of SentenceEdge.tla UnitStart.
    static func offsetAtUnitStart(
        _ text: String,
        caret: Int?,
        ranges: [SentenceRange]
    ) -> Int {
        let len = text.count
        let pos = min(max(caret ?? len, 0), len)
        guard let idx = rangeIndexContaining(pos, ranges: ranges) else { return 0 }
        return ranges[idx].start
    }

    /// End of the unit under caret (before separator / next unit).
    /// Dual of SentenceEdge.tla UnitEnd.
    static func offsetAtUnitEnd(
        _ text: String,
        caret: Int?,
        ranges: [SentenceRange]
    ) -> Int {
        let len = text.count
        let pos = min(max(caret ?? len, 0), len)
        guard let idx = rangeIndexContaining(pos, ranges: ranges) else { return len }
        return ranges[idx].end
    }

    /// Dual of SentenceEdge.tla — sentence under caret.
    static func offsetAtSentenceStart(_ text: String, caret: Int?) -> Int {
        offsetAtUnitStart(text, caret: caret, ranges: sentenceRanges(text))
    }

    static func offsetAtSentenceEnd(_ text: String, caret: Int?) -> Int {
        offsetAtUnitEnd(text, caret: caret, ranges: sentenceRanges(text))
    }

    /// Dual of SentenceEdge.tla — paragraph under caret.
    static func offsetAtParagraphStart(_ text: String, caret: Int?) -> Int {
        offsetAtUnitStart(text, caret: caret, ranges: paragraphRanges(text))
    }

    static func offsetAtParagraphEnd(_ text: String, caret: Int?) -> Int {
        offsetAtUnitEnd(text, caret: caret, ranges: paragraphRanges(text))
    }

    /// Session caret after ↑ / ↓ by `count` lines, preserving column when possible.
    /// `caret == nil` means end of buffer. Dual of LineCaret.tla MoveUp/MoveDown.
    static func offsetAfterLineMove(
        _ text: String,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> Int {
        let len = text.count
        var pos = min(max(caret ?? len, 0), len)
        guard count > 0 else { return pos }
        let ranges = lineRanges(text)
        guard !ranges.isEmpty else { return pos }

        for _ in 0..<count {
            guard let idx = lineIndexContaining(pos, ranges: ranges) else { break }
            let col = pos - ranges[idx].start
            if up {
                guard idx > 0 else {
                    let first = ranges[0]
                    pos = first.start + min(col, first.end - first.start)
                    break
                }
                let prev = ranges[idx - 1]
                pos = prev.start + min(col, prev.end - prev.start)
            } else {
                guard idx + 1 < ranges.count else {
                    let last = ranges[idx]
                    pos = last.start + min(col, last.end - last.start)
                    break
                }
                let next = ranges[idx + 1]
                pos = next.start + min(col, next.end - next.start)
            }
        }
        return pos
    }

    /// Jump `count` units up/down to unit start (sentence or paragraph ranges).
    private static func offsetAfterUnitMove(
        ranges: [SentenceRange],
        caret: Int?,
        textCount: Int,
        up: Bool,
        count: Int
    ) -> Int {
        let pos = min(max(caret ?? textCount, 0), textCount)
        guard count > 0 else { return pos }
        guard !ranges.isEmpty else { return pos }
        guard let startIdx = rangeIndexContaining(pos, ranges: ranges) else {
            return ranges[0].start
        }
        let targetIdx: Int
        if up {
            targetIdx = max(0, startIdx - count)
        } else {
            targetIdx = min(ranges.count - 1, startIdx + count)
        }
        return ranges[targetIdx].start
    }

    /// Session caret after moving `count` paragraphs up/down to paragraph start.
    /// Dual of MoveParagraphsN.tla. `caret == nil` means end of buffer.
    static func offsetAfterParagraphMove(
        _ text: String,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> Int {
        offsetAfterUnitMove(
            ranges: paragraphRanges(text),
            caret: caret,
            textCount: text.count,
            up: up,
            count: count
        )
    }

    /// Session caret after moving `count` sentences up/down to sentence start.
    /// Dual of MoveSentencesN.tla. `caret == nil` means end of buffer.
    static func offsetAfterSentenceMove(
        _ text: String,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> Int {
        offsetAfterUnitMove(
            ranges: sentenceRanges(text),
            caret: caret,
            textCount: text.count,
            up: up,
            count: count
        )
    }

    /// Shared span for selecting `count` units (sentence/paragraph) from caret.
    private static func selectUnitsSpan(
        ranges: [SentenceRange],
        textCount: Int,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> (start: Int, length: Int, navIndex: Int)? {
        guard count > 0, textCount > 0, !ranges.isEmpty else { return nil }
        let pos = min(max(caret ?? textCount, 0), textCount)
        guard let idx = rangeIndexContaining(pos, ranges: ranges) else { return nil }
        let n = min(count, ranges.count)
        let startIdx: Int
        let endIdx: Int
        if up {
            startIdx = max(0, idx - n + 1)
            endIdx = idx
        } else {
            startIdx = idx
            endIdx = min(ranges.count - 1, idx + n - 1)
        }
        let start = ranges[startIdx].start
        let end = ranges[endIdx].end
        guard end > start else { return nil }
        return (start, end - start, up ? startIdx : endIdx)
    }

    /// Span for selecting `count` paragraphs up/down from caret (inclusive).
    /// Dual of SelectParagraphsN.tla. Nil when empty or count ≤ 0.
    static func selectParagraphsSpan(
        _ text: String,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> (start: Int, length: Int, navIndex: Int)? {
        selectUnitsSpan(
            ranges: paragraphRanges(text),
            textCount: text.count,
            caret: caret,
            up: up,
            count: count
        )
    }

    /// Span for selecting `count` sentences up/down from caret (inclusive).
    /// Dual of SelectSentencesN.tla. Nil when empty or count ≤ 0.
    static func selectSentencesSpan(
        _ text: String,
        caret: Int?,
        up: Bool,
        count: Int
    ) -> (start: Int, length: Int, navIndex: Int)? {
        selectUnitsSpan(
            ranges: sentenceRanges(text),
            textCount: text.count,
            caret: caret,
            up: up,
            count: count
        )
    }

    /// Start of the line under caret. Dual of LineCaret.tla LineStart.
    static func offsetAtLineStart(_ text: String, caret: Int?) -> Int {
        offsetAtUnitStart(text, caret: caret, ranges: lineRanges(text))
    }

    /// End of the line under caret (before `\n` / buffer end). Dual of LineCaret.tla LineEnd.
    static func offsetAtLineEnd(_ text: String, caret: Int?) -> Int {
        offsetAtUnitEnd(text, caret: caret, ranges: lineRanges(text))
    }
}
