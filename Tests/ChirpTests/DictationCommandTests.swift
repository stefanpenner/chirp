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
        #expect(DictationCommand.parse("correct that") == .scratchThat)
        #expect(DictationCommand.parse("fix that") == .scratchThat)
        #expect(DictationCommand.parse("please correct that") == .scratchThat)
        #expect(DictationCommand.parse("replace that") == .replaceThat)
        #expect(DictationCommand.parse("swap that") == .replaceThat)
        #expect(DictationCommand.parse("please replace that") == .replaceThat)
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

    @Test("recognizes caps mode and one-shot transforms")
    func capsCommands() {
        #expect(DictationCommand.parse("all caps on") == .setCapsMode(.allCaps))
        #expect(DictationCommand.parse("all caps") == .setCapsMode(.allCaps))
        #expect(DictationCommand.parse("no caps on") == .setCapsMode(.noCaps))
        #expect(DictationCommand.parse("caps on") == .setCapsMode(.capsOn))
        #expect(DictationCommand.parse("caps off") == .setCapsMode(.normal))
        #expect(DictationCommand.parse("normal caps") == .setCapsMode(.normal))
        #expect(DictationCommand.parse("cap that") == .capThat)
        #expect(DictationCommand.parse("capitalize that") == .capThat)
        #expect(DictationCommand.parse("all caps that") == .allCapsThat)
        #expect(DictationCommand.parse("no caps that") == .noCapsThat)
        #expect(DictationCommand.parse("title case that") == .titleCaseThat)
        #expect(DictationCommand.parse("title case that phrase") == .titleCaseThat)
        #expect(DictationCommand.parse("sentence case that") == .sentenceCaseThat)
        #expect(DictationCommand.parse("no space that") == .noSpaceThat)
        #expect(DictationCommand.parse("please all caps on") == .setCapsMode(.allCaps))
    }

    @Test("recognizes spell mode on and off")
    func spellModeCommands() {
        #expect(DictationCommand.parse("spell mode") == .setSpellMode(.on))
        #expect(DictationCommand.parse("spelling mode") == .setSpellMode(.on))
        #expect(DictationCommand.parse("start spelling") == .setSpellMode(.on))
        #expect(DictationCommand.parse("spell on") == .setSpellMode(.on))
        #expect(DictationCommand.parse("end spell") == .setSpellMode(.off))
        #expect(DictationCommand.parse("end spelling") == .setSpellMode(.off))
        #expect(DictationCommand.parse("spell mode off") == .setSpellMode(.off))
        #expect(DictationCommand.parse("dictation mode") == .setSpellMode(.off))
        #expect(DictationCommand.parse("spell off") == .setSpellMode(.off))
        #expect(DictationCommand.parse("please spell mode") == .setSpellMode(.on))
        #expect(DictationCommand.parse("Spell Mode Off.") == .setSpellMode(.off))
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

    @Test("recognizes select that / select last word / select all")
    func selectCommands() {
        #expect(DictationCommand.parse("select that") == .selectThat)
        #expect(DictationCommand.parse("Select that.") == .selectThat)
        #expect(DictationCommand.parse("select it") == .selectThat)
        #expect(DictationCommand.parse("select last") == .selectThat)
        #expect(DictationCommand.parse("highlight that") == .selectThat)
        #expect(DictationCommand.parse("please select that") == .selectThat)
        #expect(DictationCommand.parse("select last word") == .selectLastWord)
        #expect(DictationCommand.parse("highlight last word") == .selectLastWord)
        #expect(DictationCommand.parse("select all") == .selectAll)
        #expect(DictationCommand.parse("highlight all") == .selectAll)
    }

    @Test("recognizes move left/right word navigation")
    func moveWordCommands() {
        #expect(DictationCommand.parse("move left") == .moveLeftWord)
        #expect(DictationCommand.parse("left word") == .moveLeftWord)
        #expect(DictationCommand.parse("previous word") == .moveLeftWord)
        #expect(DictationCommand.parse("go left") == .moveLeftWord)
        #expect(DictationCommand.parse("back one word") == .moveLeftWord)
        #expect(DictationCommand.parse("Move left.") == .moveLeftWord)
        #expect(DictationCommand.parse("please move left") == .moveLeftWord)

        #expect(DictationCommand.parse("move right") == .moveRightWord)
        #expect(DictationCommand.parse("right word") == .moveRightWord)
        #expect(DictationCommand.parse("next word") == .moveRightWord)
        #expect(DictationCommand.parse("go right") == .moveRightWord)
        #expect(DictationCommand.parse("forward one word") == .moveRightWord)
        #expect(DictationCommand.parse("please go right") == .moveRightWord)
    }

    @Test("recognizes move to line start/end")
    func moveLineCommands() {
        #expect(DictationCommand.parse("go to start") == .moveToStart)
        #expect(DictationCommand.parse("go to beginning") == .moveToStart)
        #expect(DictationCommand.parse("beginning of line") == .moveToStart)
        #expect(DictationCommand.parse("please go to start") == .moveToStart)

        #expect(DictationCommand.parse("go to end") == .moveToEnd)
        #expect(DictationCommand.parse("end of line") == .moveToEnd)
        #expect(DictationCommand.parse("please go to end") == .moveToEnd)
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
        #expect(says.contains(where: { $0.lowercased().contains("select that") }))
        #expect(says.contains(where: { $0.lowercased().contains("move left") }))
        #expect(says.contains(where: { $0.lowercased().contains("move right") }))
    }
}
