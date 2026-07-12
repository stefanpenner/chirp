// CommandPhraseEval.swift — Command recognition hit rate (SOTA voice-agent eval).
// Short command utterances fail ASR more than long-form dictation; gate both
// perfect transcripts and known near-misses through DictationCommand.parse.
// Pure dual — no model dependency. Live soak: AudioCorpusPipelineTests.

import Foundation

enum CommandPhraseEval {
    /// One ASR hypothesis vs the command we intended.
    struct Trial: Equatable, Sendable {
        let hyp: String
        let expected: DictationCommand
    }

    /// Hotword phrases that are **content** rewrites (TextPostProcessor), not
    /// DictationCommand — still valid for ASR bias, excluded from parse gates.
    static let contentOnlyHotwords: Set<String> = [
        "new line",
        "new paragraph",
    ]

    /// Incomplete prefixes used only for ASR bias (need an argument to parse).
    static let openPhraseHotwords: Set<String> = [
        "resume with",
        "insert before",
        "insert after",
    ]

    /// True when hyp parses to exactly `expected`.
    static func hit(_ trial: Trial) -> Bool {
        DictationCommand.parse(trial.hyp) == trial.expected
    }

    /// Fraction of trials that hit. Empty → 1.0 (vacuous success).
    static func hitRate(_ trials: [Trial]) -> Double {
        guard !trials.isEmpty else { return 1.0 }
        let hits = trials.reduce(0) { $0 + (hit($1) ? 1 : 0) }
        return Double(hits) / Double(trials.count)
    }

    /// Golden always-on set: clean transcripts + known ASR near-misses.
    /// Hit rate must stay 1.0 in unit tests.
    static let goldenTrials: [Trial] = [
        // Scratch / undo
        Trial(hyp: "scratch that", expected: .scratchThat(count: 1)),
        Trial(hyp: "scratch hat", expected: .scratchThat(count: 1)),
        Trial(hyp: "scrap that", expected: .scratchThat(count: 1)),
        Trial(hyp: "scrap hat", expected: .scratchThat(count: 1)),
        Trial(hyp: "undo hat", expected: .scratchThat(count: 1)),
        Trial(hyp: "scratched that", expected: .scratchThat(count: 1)),
        Trial(hyp: "correct that", expected: .scratchThat(count: 1)),
        Trial(hyp: "scratch that 3 times", expected: .scratchThat(count: 3)),
        // Select
        Trial(hyp: "select that", expected: .selectThat),
        Trial(hyp: "selected that", expected: .selectThat),
        Trial(hyp: "select dat", expected: .selectThat),
        Trial(hyp: "select again", expected: .selectAgain),
        Trial(hyp: "select a gain", expected: .selectAgain),
        Trial(hyp: "select tht", expected: .selectThat), // fuzzy edit-1
        Trial(hyp: "press esape", expected: .pressEscape(count: 1)),
        Trial(hyp: "Ball Dad.", expected: .boldThat), // live soak dump
        Trial(hyp: "select last word", expected: .selectLastWord),
        Trial(hyp: "select last sentence", expected: .selectLastSentence),
        Trial(hyp: "select all", expected: .selectAll),
        // Keys
        Trial(hyp: "press escape", expected: .pressEscape(count: 1)),
        Trial(hyp: "press escape 3 times", expected: .pressEscape(count: 3)),
        Trial(hyp: "press backspace", expected: .pressBackspace(count: 1)),
        Trial(hyp: "press back space", expected: .pressBackspace(count: 1)),
        Trial(hyp: "Press back space.", expected: .pressBackspace(count: 1)),
        Trial(hyp: "press enter", expected: .pressEnter(count: 1)),
        Trial(hyp: "press tab", expected: .pressTab(count: 1)),
        Trial(hyp: "press space", expected: .pressSpace(count: 1)),
        Trial(hyp: "forward delete", expected: .pressForwardDelete(count: 1)),
        // Caps / spell
        Trial(hyp: "cap that", expected: .capThat),
        Trial(hyp: "Capta", expected: .capThat), // live soak dump
        Trial(hyp: "capthat", expected: .capThat),
        Trial(hyp: "Hap that.", expected: .capThat), // multi-voice Daniel
        Trial(hyp: "hap that", expected: .capThat),
        Trial(hyp: "Have that.", expected: .capThat),
        Trial(hyp: "Bulldog.", expected: .boldThat),
        Trial(hyp: "Build that.", expected: .boldThat),
        Trial(hyp: "Face that", expected: .pasteThat),
        Trial(hyp: "Until that.", expected: .scratchThat(count: 1)), // → undo that
        Trial(hyp: "We do that.", expected: .redoThat(count: 1)),
        Trial(hyp: "Select lost words.", expected: .selectLastWord),
        Trial(hyp: "Scratch badge.", expected: .scratchThat(count: 1)),
        Trial(hyp: "Hey Dad.", expected: .pasteThat),
        Trial(hyp: "Chris Escape", expected: .pressEscape(count: 1)),
        Trial(hyp: "all caps that", expected: .allCapsThat),
        Trial(hyp: "spell that", expected: .spellThat),
        Trial(hyp: "spell mode", expected: .setSpellMode(.on)),
        // Clipboard
        Trial(hyp: "copy that", expected: .copyThat),
        Trial(hyp: "paste that", expected: .pasteThat),
        Trial(hyp: "taste that", expected: .pasteThat), // ASR paste→taste
        Trial(hyp: "Taste that.", expected: .pasteThat),
        Trial(hyp: "Haste that.", expected: .pasteThat), // multi-voice Tessa
        Trial(hyp: "cut that", expected: .cutThat),
        Trial(hyp: "Cartage", expected: .cutThat), // multi-voice Moira
        Trial(hyp: "Italic Dutch", expected: .italicThat), // multi-voice Moira
        Trial(hyp: "It chalic that.", expected: .italicThat), // multi-voice Tessa
        Trial(hyp: "duplicate that", expected: .duplicateThat),
        // Redo / replace
        Trial(hyp: "redo that", expected: .redoThat(count: 1)),
        Trial(hyp: "replace that", expected: .replaceThat),
        // Nav
        Trial(hyp: "go to start", expected: .moveToStart),
        Trial(hyp: "go to end", expected: .moveToEnd),
        Trial(hyp: "unselect that", expected: .unselectThat),
    ]

    /// Spoken phrases for live TTS → ASR → parse soak (manual corpus).
    /// `spoken` is what TTS says; `expected` is the command after post-process.
    static let soakPhrases: [(id: String, spoken: String, expected: DictationCommand)] = [
        ("cmd_scratch", "scratch that", .scratchThat(count: 1)),
        ("cmd_select_that", "select that", .selectThat),
        ("cmd_select_again", "select again", .selectAgain),
        ("cmd_select_word", "select last word", .selectLastWord),
        ("cmd_select_sentence", "select last sentence", .selectLastSentence),
        ("cmd_escape", "press escape", .pressEscape(count: 1)),
        ("cmd_backspace", "press backspace", .pressBackspace(count: 1)),
        ("cmd_enter", "press enter", .pressEnter(count: 1)),
        ("cmd_tab", "press tab", .pressTab(count: 1)),
        ("cmd_space", "press space", .pressSpace(count: 1)),
        ("cmd_cap", "cap that", .capThat),
        ("cmd_copy", "copy that", .copyThat),
        ("cmd_paste", "paste that", .pasteThat),
        ("cmd_cut", "cut that", .cutThat),
        ("cmd_bold", "bold that", .boldThat),
        ("cmd_italic", "italic that", .italicThat),
        ("cmd_underline", "underline that", .underlineThat),
        ("cmd_spell", "spell that", .spellThat),
        ("cmd_go_start", "go to start", .moveToStart),
        ("cmd_undo_that", "undo that", .scratchThat(count: 1)),
        ("cmd_redo", "redo that", .redoThat(count: 1)),
        ("cmd_replace", "replace that", .replaceThat),
    ]

    /// Soft budget for live soak: at least this fraction of commands must parse
    /// correctly after TTS → Parakeet (short commands are ASR-hard).
    /// Raised after fuzzy full-utterance repair (was 0.80).
    static let soakMinHitRate: Double = 0.90

    /// Core subset for multi-voice soak (latency × voices). High-frequency +
    /// weaker commands that often fail under accent variance.
    /// Expanded after 100% hit on 12 phrases × 6 regional voices (raise floors).
    static let multiVoiceSoakPhrases: [(id: String, spoken: String, expected: DictationCommand)] = [
        ("mv_scratch", "scratch that", .scratchThat(count: 1)),
        ("mv_select", "select that", .selectThat),
        ("mv_again", "select again", .selectAgain),
        ("mv_word", "select last word", .selectLastWord),
        ("mv_escape", "press escape", .pressEscape(count: 1)),
        ("mv_enter", "press enter", .pressEnter(count: 1)),
        ("mv_cap", "cap that", .capThat),
        ("mv_copy", "copy that", .copyThat),
        ("mv_paste", "paste that", .pasteThat),
        ("mv_bold", "bold that", .boldThat),
        ("mv_undo", "undo that", .scratchThat(count: 1)),
        ("mv_redo", "redo that", .redoThat(count: 1)),
        // Expanded set (format + nav + edit) — multi-accent robustness
        ("mv_cut", "cut that", .cutThat),
        ("mv_italic", "italic that", .italicThat),
        ("mv_underline", "underline that", .underlineThat),
        ("mv_spell", "spell that", .spellThat),
        ("mv_replace", "replace that", .replaceThat),
        ("mv_go_start", "go to start", .moveToStart),
    ]

    /// Candidate macOS `say` voices for multi-voice soak (regional English).
    /// Prefer natural dictation-like voices; skip novelty (Fred/Bells/…) and
    /// weak neural variants that are not representative of user speech.
    /// Unavailable voices are skipped by the harness probe.
    static let multiVoiceCandidates: [String] = [
        // US
        "Samantha", "Alex",
        // UK
        "Daniel",
        // AU / IE / ZA / IN
        "Karen", "Moira", "Tessa", "Rishi",
    ]

    /// Overall multi-voice command hit budget (pooled trials).
    /// Raised after 100% on 12×6 regional (was 0.85); locks SOTA floor.
    static let multiVoiceSoakMinHitRate: Double = 0.90

    /// Worst single voice must still clear this floor (was 0.70).
    static let multiVoiceMinPerVoiceHitRate: Double = 0.80

    /// Minimum distinct TTS voices required for a multi-voice soak to count.
    static let multiVoiceMinVoices = 2

    /// Pooled hit rate (same as `hitRate` on flattened trials).
    static func multiVoicePooledHitRate(_ trials: [Trial]) -> Double {
        hitRate(trials)
    }

    /// Minimum hit rate among voice groups. Empty → 1.0.
    static func minPerVoiceHitRate(
        trialsByVoice: [String: [Trial]]
    ) -> Double {
        guard !trialsByVoice.isEmpty else { return 1.0 }
        return trialsByVoice.values.map { hitRate($0) }.min() ?? 1.0
    }

    /// Command-bias hotwords that must parse as commands (excludes content/open).
    static func commandBiasPhrases(
        from hotwords: [String] = CommandHotwords.phrases
    ) -> [String] {
        hotwords.filter { p in
            !contentOnlyHotwords.contains(p) && !openPhraseHotwords.contains(p)
        }
    }

    /// True when every command-bias hotword parses as some command.
    static func allCommandHotwordsParse(
        phrases: [String] = commandBiasPhrases()
    ) -> Bool {
        phrases.allSatisfy { DictationCommand.parse($0).isCommand }
    }
}
