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

    @Test("normal text is not a command")
    func normalText() {
        #expect(DictationCommand.parse("hello world") == .none)
        #expect(DictationCommand.parse("scratch the surface") == .none)
        #expect(DictationCommand.parse("") == .none)
    }
}
