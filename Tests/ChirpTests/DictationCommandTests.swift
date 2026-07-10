// DictationCommandTests.swift — Spoken edit command parsing.

import Testing
@testable import Chirp

@Suite("DictationCommand")
struct DictationCommandTests {

    @Test("recognizes scratch/delete/undo variants")
    func scratchVariants() {
        #expect(DictationCommand.parse("scratch that") == .scratchThat)
        #expect(DictationCommand.parse("Scratch that.") == .scratchThat)
        #expect(DictationCommand.parse("delete that") == .scratchThat)
        #expect(DictationCommand.parse("UNDO THAT!") == .scratchThat)
        #expect(DictationCommand.parse("scrap that") == .scratchThat)
        #expect(DictationCommand.parse("delete it") == .scratchThat)
    }

    @Test("recognizes delete last word")
    func deleteLastWord() {
        #expect(DictationCommand.parse("delete last word") == .deleteLastWord)
        #expect(DictationCommand.parse("scratch word") == .deleteLastWord)
        #expect(DictationCommand.parse("undo word.") == .deleteLastWord)
    }

    @Test("recognizes clear all")
    func clearAll() {
        #expect(DictationCommand.parse("clear all") == .clearAll)
        #expect(DictationCommand.parse("start over") == .clearAll)
        #expect(DictationCommand.parse("delete everything!") == .clearAll)
    }

    @Test("recognizes press enter and tab")
    func pressKeys() {
        #expect(DictationCommand.parse("press enter") == .pressEnter)
        #expect(DictationCommand.parse("hit return") == .pressEnter)
        #expect(DictationCommand.parse("press tab") == .pressTab)
    }

    @Test("recognizes copy and paste")
    func copyPaste() {
        #expect(DictationCommand.parse("copy that") == .copyThat)
        #expect(DictationCommand.parse("copy all") == .copyThat)
        #expect(DictationCommand.parse("paste that") == .pasteThat)
        #expect(DictationCommand.parse("paste this") == .pasteThat)
    }

    @Test("recognizes redo that")
    func redoThat() {
        #expect(DictationCommand.parse("redo that") == .redoThat)
        #expect(DictationCommand.parse("Redo it.") == .redoThat)
        #expect(DictationCommand.parse("restore that") == .redoThat)
        #expect(DictationCommand.parse("undo undo") == .redoThat)
        #expect(DictationCommand.parse("put it back") == .redoThat)
    }

    @Test("tolerates please / now around commands")
    func politenessTolerance() {
        #expect(DictationCommand.parse("scratch that please") == .scratchThat)
        #expect(DictationCommand.parse("please scratch that") == .scratchThat)
        #expect(DictationCommand.parse("please undo that now") == .scratchThat)
        #expect(DictationCommand.parse("clear all please") == .clearAll)
        #expect(DictationCommand.parse("please copy that") == .copyThat)
        #expect(DictationCommand.parse("redo that please") == .redoThat)
    }

    @Test("extra aliases and ASR near-misses")
    func aliasesAndNearMisses() {
        #expect(DictationCommand.parse("delete the last word") == .deleteLastWord)
        #expect(DictationCommand.parse("remove the last word") == .deleteLastWord)
        #expect(DictationCommand.parse("scratch last") == .deleteLastWord)
        #expect(DictationCommand.parse("scratch hat") == .scratchThat)
        #expect(DictationCommand.parse("go back") == .scratchThat)
        #expect(DictationCommand.parse("press the enter key") == .pressEnter)
    }

    @Test("normal text is not a command")
    func normalText() {
        #expect(DictationCommand.parse("hello world") == .none)
        #expect(DictationCommand.parse("scratch the surface") == .none)
        #expect(DictationCommand.parse("please send the report") == .none)
        #expect(DictationCommand.parse("") == .none)
    }

    @Test("help catalog is non-empty and unique")
    func helpCatalog() {
        #expect(DictationCommand.helpCatalog.count >= 8)
        let says = DictationCommand.helpCatalog.map(\.say)
        #expect(Set(says).count == says.count)
    }
}
