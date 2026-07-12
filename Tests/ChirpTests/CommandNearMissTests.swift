// CommandNearMissTests.swift — Pure dual of full-utterance ASR command repair.

import Testing
@testable import Chirp

@Suite("CommandNearMiss")
struct CommandNearMissTests {

    @Test("cap that collapsed ASR dumps repair")
    func capThatDumps() {
        #expect(CommandNearMiss.repair("Capta") == "cap that")
        #expect(CommandNearMiss.repair("capta.") == "cap that")
        #expect(CommandNearMiss.repair("cap ta") == "cap that")
        #expect(CommandNearMiss.repair("capthat") == "cap that")
        #expect(DictationCommand.parse("Capta") == .capThat)
        #expect(DictationCommand.parse("capthat") == .capThat)
        // Multi-voice Daniel TTS dump
        #expect(CommandNearMiss.repair("Hap that.") == "cap that")
        #expect(DictationCommand.parse("Hap that.") == .capThat)
        #expect(DictationCommand.parse("hap that") == .capThat)
        #expect(DictationCommand.parse("Have that.") == .capThat)
    }

    @Test("multi-voice accent dumps repair to commands")
    func multiVoiceAccentDumps() {
        #expect(DictationCommand.parse("Bulldog.") == .boldThat)
        #expect(DictationCommand.parse("Build that.") == .boldThat)
        #expect(DictationCommand.parse("Face that") == .pasteThat)
        #expect(DictationCommand.parse("Haste that.") == .pasteThat) // Tessa
        #expect(DictationCommand.parse("Cartage") == .cutThat) // Moira
        #expect(DictationCommand.parse("Italic Dutch") == .italicThat) // Moira
        #expect(DictationCommand.parse("It chalic that.") == .italicThat) // Tessa
        #expect(DictationCommand.parse("Until that.") == .scratchThat(count: 1))
        #expect(DictationCommand.parse("We do that.") == .redoThat(count: 1))
        #expect(DictationCommand.parse("Select lost words.") == .selectLastWord)
        // Free dictation must not steal (multi-word / mid-sentence)
        #expect(DictationCommand.parse("we do that every day") == .none)
        #expect(DictationCommand.parse("have that ready") == .none)
        #expect(DictationCommand.parse("build that house carefully") == .none)
        #expect(DictationCommand.parse("hey dad how are you") == .none)
        #expect(DictationCommand.parse("under that shelf") == .none)
        #expect(DictationCommand.parse("escape") == .none)
    }

    @Test("paste and backspace soak dumps repair")
    func pasteBackspace() {
        #expect(CommandNearMiss.repair("Taste that.") == "paste that")
        #expect(DictationCommand.parse("Taste that.") == .pasteThat)
        #expect(CommandNearMiss.repair("Haste that.") == "paste that")
        #expect(DictationCommand.parse("Haste that.") == .pasteThat)
        #expect(CommandNearMiss.repair("Press back space.") == "press backspace")
        #expect(DictationCommand.parse("Press back space.") == .pressBackspace(count: 1))
        #expect(CommandNearMiss.repair("Ball Dad.") == "bold that")
        #expect(DictationCommand.parse("Ball Dad.") == .boldThat)
    }

    @Test("glued fill/deselect surfaces expand")
    func expandedSurfacesGlue() {
        #expect(CommandNearMiss.repair("deselectthat") == "deselect that")
        #expect(CommandNearMiss.repair("italicizethat") == "italicize that")
    }

    @Test("glued multi-word commands expand")
    func gluedExpand() {
        #expect(CommandNearMiss.repair("scratchthat") == "scratch that")
        #expect(DictationCommand.parse("scratchthat") == .scratchThat(count: 1))
        #expect(CommandNearMiss.repair("selectagain") == "select again")
        #expect(DictationCommand.parse("selectagain") == .selectAgain)
    }

    @Test("free dictation mid-phrase is not repaired")
    func freeDictationUntouched() {
        let free = "please cap that bottle for me"
        #expect(CommandNearMiss.repair(free) == free)
        #expect(DictationCommand.parse(free) == .none)
        let kept = "kept that for later"
        #expect(CommandNearMiss.repair(kept) == kept)
    }

    @Test("normalizeKey strips punct and case")
    func normalizeKey() {
        #expect(CommandNearMiss.normalizeKey("  Cap That! ") == "cap that")
        #expect(CommandNearMiss.normalizeKey("") == "")
    }

    @Test("levenshtein distance is symmetric and zero for equal")
    func levenshtein() {
        #expect(CommandNearMiss.levenshtein("select that", "select that") == 0)
        #expect(CommandNearMiss.levenshtein("select tht", "select that") == 1)
        #expect(CommandNearMiss.levenshtein("select that", "select tht") == 1)
        #expect(CommandNearMiss.levenshtein("", "ab") == 2)
        #expect(CommandNearMiss.levenshtein("ab", "") == 2)
    }

    @Test("fuzzyMatch unique edit-1 with command starter")
    func fuzzyUnique() {
        #expect(CommandNearMiss.fuzzyMatch("select tht") == "select that")
        #expect(CommandNearMiss.fuzzyMatch("slect that") == "select that")
        #expect(CommandNearMiss.repair("select tht") == "select that")
        #expect(DictationCommand.parse("select tht") == .selectThat)
        #expect(CommandNearMiss.fuzzyMatch("press esape") == "press escape")
        #expect(DictationCommand.parse("press esape") == .pressEscape(count: 1))
    }

    /// Dual of FuzzyCommand.tla Decide (abstract gates + dist summary).
    @Test("fuzzy decision table matches FuzzyCommand.tla")
    func fuzzyDecisionDual() {
        // decide(starter, short, multi, nInRange, minDist, ties) — product gate summary
        func decide(
            starter: Bool, short: Bool, multi: Bool,
            n: Int, minDist: Int, ties: Int
        ) -> String {
            if !starter || !short || !multi || n == 0 || minDist < 0 { return "none" }
            if minDist == 0 { return ties == 1 ? "exact" : "ambiguous" }
            if minDist >= 1 && minDist <= CommandNearMiss.maxFuzzyDistance {
                return ties == 1 ? "match" : "ambiguous"
            }
            return "none"
        }
        #expect(decide(starter: true, short: true, multi: true, n: 1, minDist: 1, ties: 1) == "match")
        #expect(decide(starter: true, short: true, multi: true, n: 2, minDist: 1, ties: 2) == "ambiguous")
        #expect(decide(starter: true, short: true, multi: true, n: 1, minDist: 0, ties: 1) == "exact")
        #expect(decide(starter: false, short: true, multi: true, n: 1, minDist: 1, ties: 1) == "none")
        #expect(decide(starter: true, short: false, multi: true, n: 1, minDist: 1, ties: 1) == "none")
        #expect(decide(starter: true, short: true, multi: false, n: 1, minDist: 1, ties: 1) == "none")
        #expect(decide(starter: true, short: true, multi: true, n: 0, minDist: -1, ties: 0) == "none")
    }

    @Test("fuzzyMatch refuses free dictation and non-starters")
    func fuzzySafe() {
        #expect(CommandNearMiss.fuzzyMatch("hello world") == nil)
        #expect(CommandNearMiss.fuzzyMatch("but that") == nil) // not a command starter
        #expect(CommandNearMiss.fuzzyMatch("hope that") == nil)
        #expect(CommandNearMiss.isCommandStarter("but") == false)
        #expect(CommandNearMiss.isCommandStarter("slect") == true) // ~select
        // Long free dictation is not rewritten (even if a command substring appears).
        let free = "please select tht for me"
        #expect(CommandNearMiss.repair(free) == free)
        #expect(CommandNearMiss.fuzzyMatch(free) == nil) // too many words / not exact surface
        #expect(CommandNearMiss.fuzzyMatch("and the quick brown fox") == nil)
    }
}
