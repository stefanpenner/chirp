// DictationCommand.swift — Spoken edit commands (SOTA dictation UX).
// Pure parse; AppState executes against TextInserter + transcript buffer.
// Tolerant of ASR trailing punctuation, politeness words, and common aliases.

import Foundation

enum DictationCommand: Equatable, Sendable {
    case none
    /// Undo the most recently typed segment (and its join separator).
    case scratchThat
    /// Arm multi-step replace: next content undoes last phrase then inserts.
    case replaceThat
    /// Delete the last whitespace-delimited word.
    case deleteLastWord
    /// Delete the last sentence (after [.?!] + whitespace).
    case deleteLastSentence
    /// Delete the second sentence (session-relative "next"). Does not steal delete last/previous.
    case deleteNextSentence
    /// Delete the last paragraph (after \n\n or \n).
    case deleteLastParagraph
    /// Delete the last line (after final \n).
    case deleteLastLine
    /// Clear the entire session transcript and typed text.
    case clearAll
    /// Insert a newline (Return key).
    case pressEnter
    /// Insert a tab.
    case pressTab
    /// Insert a space character.
    case pressSpace
    /// Press Backspace / Delete once. Keyboard-only; buffer unchanged.
    case pressBackspace
    /// Press Escape once. Keyboard-only; buffer unchanged; does not cancel session.
    case pressEscape
    /// System undo (⌘Z). Keyboard-only; buffer / edit stack unchanged.
    case pressUndo
    /// System redo (⌘⇧Z). Keyboard-only; buffer / edit stack unchanged.
    case pressRedo
    /// Press Forward Delete once. Keyboard-only; buffer unchanged.
    case pressForwardDelete
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
    /// Redo the last scratched segment.
    case redoThat
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
    /// Select the last typed phrase (shift+left over last stack delta).
    case selectThat
    /// Select the last whitespace-delimited word.
    case selectLastWord
    /// Select next word via ⇧⌥→. Keyboard-only; buffer unchanged.
    case selectNextWord
    /// Select previous word via ⇧⌥←. Keyboard-only; buffer unchanged.
    case selectPreviousWord
    /// Delete next word via ⇧⌥→ then backspace. Keyboard-only; buffer unchanged.
    case deleteNextWord
    /// Select the last sentence (after [.?!] + whitespace).
    case selectLastSentence
    /// Select the first sentence (before first [.?!] + whitespace).
    case selectFirstSentence
    /// Select the second sentence (session-relative "next"). Buffer unchanged.
    case selectNextSentence
    /// Select the last paragraph (after \n\n or \n).
    case selectLastParagraph
    /// Select the first paragraph (before first \n\n or \n).
    case selectFirstParagraph
    /// Select the second paragraph (session-relative "next"). Buffer unchanged.
    case selectNextParagraph
    /// Select the last line (after final \n).
    case selectLastLine
    /// Select the first line (before first \n).
    case selectFirstLine
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
    /// Move cursor one line up (↑). Buffer unchanged.
    case moveUpLine
    /// Move cursor one line down (↓). Buffer unchanged.
    case moveDownLine
    /// Move cursor to line start (⌘←). Buffer unchanged.
    case moveToStart
    /// Move cursor to line end (⌘→). Buffer unchanged.
    case moveToEnd
    /// Move cursor to document start (⌘↑). Buffer unchanged.
    case moveToDocumentStart
    /// Move cursor to document end (⌘↓). Buffer unchanged.
    case moveToDocumentEnd
    /// Scroll one page up (Page Up). Buffer unchanged.
    case pageUp
    /// Scroll one page down (Page Down). Buffer unchanged.
    case pageDown
    /// Move cursor to start of last sentence (plain ← × n). Buffer unchanged.
    case moveToPreviousSentence
    /// Move cursor to start of second sentence (← × full, then → past first). Buffer unchanged.
    case moveToNextSentence

    /// Parse a post-processed segment into a command, or `.none` for normal text.
    static func parse(_ text: String) -> DictationCommand {
        let candidates = normalizeCandidates(text)
        for candidate in candidates {
            if let cmd = matchExact(candidate) {
                return cmd
            }
        }
        return .none
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
            return .scratchThat
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
        // Do not steal "delete last sentence" / "delete previous sentence".
        case "delete next sentence", "delete forward sentence",
             "remove next sentence", "remove forward sentence":
            return .deleteNextSentence
        case "delete last paragraph", "delete previous paragraph", "delete paragraph",
             "remove last paragraph", "remove previous paragraph", "remove paragraph":
            return .deleteLastParagraph
        case "delete last line", "delete previous line", "delete line",
             "remove last line", "remove previous line", "remove line":
            return .deleteLastLine
        case "clear all", "delete all", "scratch all", "clear everything",
             "start over", "delete everything", "clear it all",
             "wipe all", "wipe everything":
            return .clearAll
        case "press enter", "press return", "hit enter", "hit return",
             "press return key", "press the enter key", "hit the enter key":
            return .pressEnter
        case "press tab", "hit tab", "press tab key", "press the tab key":
            return .pressTab
        // Explicit press/hit only — bare "space bar" is content ITN → " ".
        case "press space", "hit space", "press space bar", "hit space bar",
             "press spacebar", "hit spacebar", "space key", "press space key",
             "hit space key":
            return .pressSpace
        // Keyboard backspace only — do not match "delete that" / "delete it"
        // (those remain scratchThat) or "delete last" (deleteLastWord).
        // Forward delete phrases are matched separately below.
        case "press backspace", "hit backspace", "backspace",
             "press delete", "hit delete", "delete key":
            return .pressBackspace
        // Forward Delete (0x75) — not laptop Delete/Backspace.
        case "forward delete", "press forward delete",
             "delete forward", "press delete forward":
            return .pressForwardDelete
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
        case "duplicate that", "duplicate it", "dupe that", "copy paste that":
            return .duplicateThat
        case "redo that", "redo it", "restore that", "undo undo",
             "redo last", "put it back":
            return .redoThat
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
        case "select last sentence", "select previous sentence",
             "select sentence", "highlight last sentence",
             "highlight previous sentence", "highlight sentence":
            return .selectLastSentence
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
        case "select last paragraph", "select previous paragraph",
             "select paragraph", "highlight last paragraph",
             "highlight previous paragraph", "highlight paragraph":
            return .selectLastParagraph
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
        case "select last line", "select previous line", "select line",
             "select this line", "highlight last line", "highlight previous line",
             "highlight line", "highlight this line":
            return .selectLastLine
        // "first" → "1st" via SpokenNumberITN before parse; match both.
        case "select first line", "select the first line",
             "select 1st line", "select the 1st line",
             "highlight first line", "highlight the first line",
             "highlight 1st line", "highlight the 1st line":
            return .selectFirstLine
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
        // Navigation — do not match "select previous line" (selectLastLine).
        case "move up", "up a line", "previous line", "go up", "line up":
            return .moveUpLine
        case "move down", "down a line", "next line", "go down", "line down":
            return .moveDownLine
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
        // Page scroll — exact phrases; "move up" / "go up" remain moveUpLine.
        case "page up", "scroll up", "scroll page up":
            return .pageUp
        case "page down", "scroll down", "scroll page down":
            return .pageDown
        // Navigation — do not match "select previous sentence" (selectLastSentence).
        case "go to previous sentence", "previous sentence",
             "move to previous sentence", "back a sentence":
            return .moveToPreviousSentence
        case "go to next sentence", "next sentence",
             "move to next sentence", "forward a sentence":
            return .moveToNextSentence
        default:
            return nil
        }
    }

    var isCommand: Bool { self != .none }

    /// User-facing command catalog for Settings / help (say → effect).
    static let helpCatalog: [(say: String, effect: String)] = [
        ("scratch that / correct that", "Undo last phrase (multi-level)"),
        ("replace that", "Next phrase replaces last (multi-step)"),
        ("redo that", "Restore last scratched phrase"),
        ("delete last word", "Remove last word"),
        ("delete last sentence / previous sentence", "Remove last sentence"),
        ("delete next sentence / delete forward sentence", "Remove second sentence (session-relative)"),
        ("delete last paragraph / previous paragraph", "Remove last paragraph"),
        ("delete last line / delete line", "Remove last line"),
        ("clear all", "Wipe session text"),
        ("press enter", "Insert Return"),
        ("press tab", "Insert Tab"),
        ("press space / hit space", "Insert Space"),
        ("press backspace / delete key", "Press Backspace once (keyboard only)"),
        ("forward delete / delete forward", "Press Forward Delete once (keyboard only; not Backspace)"),
        ("press escape / escape key", "Press Escape once (keyboard only; does not cancel)"),
        ("system undo / press undo / undo key", "System undo (⌘Z; keyboard only; not scratch that)"),
        ("system redo / press redo / redo key", "System redo (⌘⇧Z; keyboard only; not redo that)"),
        ("insert date / today's date", "Type today's date (e.g. July 10, 2026)"),
        ("insert time / current time", "Type current time (e.g. 3:45 p.m.)"),
        ("copy that", "Copy session to clipboard"),
        ("paste that", "Paste clipboard (⌘V)"),
        ("duplicate that / dupe that", "Copy last phrase and paste again"),
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
        ("select next word / select forward word", "Select next word (⇧⌥→; keyboard only)"),
        ("select previous word / select prior word", "Select previous word (⇧⌥←; keyboard only)"),
        ("delete next word / delete forward word", "Delete next word (⇧⌥→ then ⌫; keyboard only)"),
        ("select last sentence / previous sentence", "Select last sentence"),
        ("select first sentence / the first sentence", "Select first sentence"),
        ("select next sentence / select forward sentence", "Select second sentence (session-relative)"),
        ("select last paragraph / previous paragraph", "Select last paragraph"),
        ("select first paragraph / the first paragraph", "Select first paragraph"),
        ("select next paragraph / select forward paragraph", "Select second paragraph (session-relative)"),
        ("select last line / select line", "Select last line"),
        ("select first line / the first line", "Select first line"),
        ("select all", "Select all (⌘A)"),
        ("unselect that / deselect", "Collapse selection (caret to end)"),
        ("bold that", "Select last phrase + bold (⌘B), then unselect"),
        ("italic that", "Select last phrase + italic (⌘I), then unselect"),
        ("underline that", "Select last phrase + underline (⌘U), then unselect"),
        ("cut that", "Select last phrase + cut (⌘X)"),
        ("move left / previous word", "Cursor left one word (⌥←)"),
        ("move right / next word", "Cursor right one word (⌥→)"),
        ("move up / previous line / line up", "Cursor up one line (↑)"),
        ("move down / next line / line down", "Cursor down one line (↓)"),
        ("go to start / beginning of line", "Cursor to line start (⌘←)"),
        ("go to end / end of line", "Cursor to line end (⌘→)"),
        ("beginning of document / top of document", "Cursor to document start (⌘↑)"),
        ("end of document / bottom of document", "Cursor to document end (⌘↓)"),
        ("page up / scroll up", "Page up (Page Up key)"),
        ("page down / scroll down", "Page down (Page Down key)"),
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
        let first = firstParagraph(text)
        guard !first.isEmpty, first.count < text.count else { return "" }
        var idx = text.index(text.startIndex, offsetBy: first.count)
        if text[idx...].hasPrefix("\n\n") {
            idx = text.index(idx, offsetBy: 2)
        } else if idx < text.endIndex && text[idx] == "\n" {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex else { return "" }
        return firstParagraph(String(text[idx...]))
    }

    /// Character offset of second-paragraph content start, or nil if none.
    static func secondParagraphStartOffset(_ text: String) -> Int? {
        let first = firstParagraph(text)
        guard !first.isEmpty, first.count < text.count else { return nil }
        var idx = text.index(text.startIndex, offsetBy: first.count)
        if text[idx...].hasPrefix("\n\n") {
            idx = text.index(idx, offsetBy: 2)
        } else if idx < text.endIndex && text[idx] == "\n" {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex else { return nil }
        guard !secondParagraph(text).isEmpty else { return nil }
        return text.distance(from: text.startIndex, to: idx)
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
}
