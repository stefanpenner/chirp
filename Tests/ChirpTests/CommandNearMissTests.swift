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
    }

    @Test("paste and backspace soak dumps repair")
    func pasteBackspace() {
        #expect(CommandNearMiss.repair("Taste that.") == "paste that")
        #expect(DictationCommand.parse("Taste that.") == .pasteThat)
        #expect(CommandNearMiss.repair("Press back space.") == "press backspace")
        #expect(DictationCommand.parse("Press back space.") == .pressBackspace(count: 1))
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
}
