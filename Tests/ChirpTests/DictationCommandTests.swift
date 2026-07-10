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

    @Test("normal text is not a command")
    func normalText() {
        #expect(DictationCommand.parse("hello world") == .none)
        #expect(DictationCommand.parse("scratch the surface") == .none)
        #expect(DictationCommand.parse("") == .none)
    }
}
