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

    @Test("recognizes press space variants")
    func pressSpace() {
        #expect(DictationCommand.parse("press space") == .pressSpace)
        #expect(DictationCommand.parse("hit space") == .pressSpace)
        #expect(DictationCommand.parse("press space bar") == .pressSpace)
        #expect(DictationCommand.parse("hit space bar") == .pressSpace)
        #expect(DictationCommand.parse("press spacebar") == .pressSpace)
        #expect(DictationCommand.parse("space key") == .pressSpace)
        #expect(DictationCommand.parse("Press Space.") == .pressSpace)
        #expect(DictationCommand.parse("please press space") == .pressSpace)
        // Content mid-sentence is not a whole-utterance command
        #expect(DictationCommand.parse("hit the space bar hard") == .none)
    }

    @Test("recognizes press backspace without stealing delete that")
    func pressBackspace() {
        #expect(DictationCommand.parse("press backspace") == .pressBackspace)
        #expect(DictationCommand.parse("hit backspace") == .pressBackspace)
        #expect(DictationCommand.parse("backspace") == .pressBackspace)
        #expect(DictationCommand.parse("press delete") == .pressBackspace)
        #expect(DictationCommand.parse("delete key") == .pressBackspace)
        #expect(DictationCommand.parse("delete that") == .scratchThat)
        #expect(DictationCommand.parse("delete it") == .scratchThat)
    }

    @Test("recognizes spell that")
    func spellThat() {
        #expect(DictationCommand.parse("spell that") == .spellThat)
        #expect(DictationCommand.parse("spell it") == .spellThat)
        #expect(DictationCommand.parse("spell last") == .spellThat)
        #expect(DictationCommand.parse("please spell that") == .spellThat)
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

    @Test("recognizes select last sentence / previous sentence")
    func selectLastSentenceCommands() {
        #expect(DictationCommand.parse("select last sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("select previous sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("select sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("Select last sentence.") == .selectLastSentence)
        #expect(DictationCommand.parse("please select previous sentence") == .selectLastSentence)
    }

    @Test("recognizes select last paragraph / previous paragraph")
    func selectLastParagraphCommands() {
        #expect(DictationCommand.parse("select last paragraph") == .selectLastParagraph)
        #expect(DictationCommand.parse("select previous paragraph") == .selectLastParagraph)
        #expect(DictationCommand.parse("select paragraph") == .selectLastParagraph)
        #expect(DictationCommand.parse("Select last paragraph.") == .selectLastParagraph)
        #expect(DictationCommand.parse("please select previous paragraph") == .selectLastParagraph)
    }

    @Test("last sentence selection boundaries")
    func lastSentenceSelection() {
        #expect(TranscriptSelection.lastSentence("") == "")
        #expect(TranscriptSelection.lastSentence("Hello world") == "Hello world")
        #expect(TranscriptSelection.lastSentence("Hello. World") == " World")
        #expect(TranscriptSelection.lastSentence("A. B. C") == " C")
        #expect(TranscriptSelection.lastSentence("Wait? Next") == " Next")
        #expect(TranscriptSelection.lastSentence("Wow! Yes") == " Yes")
        #expect(TranscriptSelection.lastSentence("Done.") == "Done.")
        // Trailing buffer content included
        #expect(TranscriptSelection.lastSentence("Hi. There  ") == " There  ")
    }

    @Test("last paragraph selection boundaries")
    func lastParagraphSelection() {
        #expect(TranscriptSelection.lastParagraph("") == "")
        #expect(TranscriptSelection.lastParagraph("Hello world") == "Hello world")
        #expect(TranscriptSelection.lastParagraph("Para one\n\nPara two") == "Para two")
        #expect(TranscriptSelection.lastParagraph("Line one\nLine two") == "Line two")
        #expect(TranscriptSelection.lastParagraph("A\n\nB\n\nC") == "C")
        // Prefer last break; blank trailing paragraph → empty after last \n\n
        #expect(TranscriptSelection.lastParagraph("Only\n\n") == "")
    }

    @Test("last line selection boundaries (content after last \\n, no leading separator)")
    func lastLineSelection() {
        #expect(TranscriptSelection.lastLine("") == "")
        #expect(TranscriptSelection.lastLine("Hello world") == "Hello world")
        #expect(TranscriptSelection.lastLine("Line one\nLine two") == "Line two")
        #expect(TranscriptSelection.lastLine("A\nB\nC") == "C")
        #expect(TranscriptSelection.lastLine("Para one\n\nPara two") == "Para two")
        // Trailing newline → empty last line
        #expect(TranscriptSelection.lastLine("Only\n") == "")
        #expect(TranscriptSelection.lastLine("Only\n\n") == "")
    }

    @Test("recognizes select last line (not move previous line)")
    func selectLastLineCommands() {
        #expect(DictationCommand.parse("select last line") == .selectLastLine)
        #expect(DictationCommand.parse("select previous line") == .selectLastLine)
        #expect(DictationCommand.parse("select line") == .selectLastLine)
        #expect(DictationCommand.parse("select this line") == .selectLastLine)
        #expect(DictationCommand.parse("Select last line.") == .selectLastLine)
        #expect(DictationCommand.parse("please select previous line") == .selectLastLine)
        #expect(DictationCommand.parse("highlight last line") == .selectLastLine)
        #expect(DictationCommand.parse("highlight line") == .selectLastLine)
    }

    @Test("recognizes bold / italic / underline that")
    func formatThatCommands() {
        #expect(DictationCommand.parse("bold that") == .boldThat)
        #expect(DictationCommand.parse("Bold that.") == .boldThat)
        #expect(DictationCommand.parse("bold it") == .boldThat)
        #expect(DictationCommand.parse("make that bold") == .boldThat)
        #expect(DictationCommand.parse("please bold that") == .boldThat)

        #expect(DictationCommand.parse("italic that") == .italicThat)
        #expect(DictationCommand.parse("italicize that") == .italicThat)
        #expect(DictationCommand.parse("italics that") == .italicThat)
        #expect(DictationCommand.parse("please italic that") == .italicThat)

        #expect(DictationCommand.parse("underline that") == .underlineThat)
        #expect(DictationCommand.parse("underline it") == .underlineThat)
        #expect(DictationCommand.parse("please underline that") == .underlineThat)
    }

    @Test("recognizes cut that")
    func cutThatCommand() {
        #expect(DictationCommand.parse("cut that") == .cutThat)
        #expect(DictationCommand.parse("Cut that.") == .cutThat)
        #expect(DictationCommand.parse("cut it") == .cutThat)
        #expect(DictationCommand.parse("cut selection") == .cutThat)
        #expect(DictationCommand.parse("please cut that") == .cutThat)
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
    func moveLineEdgeCommands() {
        #expect(DictationCommand.parse("go to start") == .moveToStart)
        #expect(DictationCommand.parse("go to beginning") == .moveToStart)
        #expect(DictationCommand.parse("beginning of line") == .moveToStart)
        #expect(DictationCommand.parse("please go to start") == .moveToStart)

        #expect(DictationCommand.parse("go to end") == .moveToEnd)
        #expect(DictationCommand.parse("end of line") == .moveToEnd)
        #expect(DictationCommand.parse("please go to end") == .moveToEnd)
    }

    @Test("recognizes move up/down line (not select previous line)")
    func moveUpDownLineCommands() {
        #expect(DictationCommand.parse("move up") == .moveUpLine)
        #expect(DictationCommand.parse("up a line") == .moveUpLine)
        #expect(DictationCommand.parse("previous line") == .moveUpLine)
        #expect(DictationCommand.parse("go up") == .moveUpLine)
        #expect(DictationCommand.parse("line up") == .moveUpLine)
        #expect(DictationCommand.parse("Move up.") == .moveUpLine)
        #expect(DictationCommand.parse("please move up") == .moveUpLine)

        #expect(DictationCommand.parse("move down") == .moveDownLine)
        #expect(DictationCommand.parse("down a line") == .moveDownLine)
        #expect(DictationCommand.parse("next line") == .moveDownLine)
        #expect(DictationCommand.parse("go down") == .moveDownLine)
        #expect(DictationCommand.parse("line down") == .moveDownLine)
        #expect(DictationCommand.parse("please go down") == .moveDownLine)

        // Select phrases must not be stolen by move
        #expect(DictationCommand.parse("select previous line") == .selectLastLine)
        #expect(DictationCommand.parse("select last line") == .selectLastLine)
        #expect(DictationCommand.parse("select line") == .selectLastLine)
        #expect(DictationCommand.parse("highlight previous line") == .selectLastLine)
    }

    @Test("recognizes duplicate that")
    func duplicateThatCommands() {
        #expect(DictationCommand.parse("duplicate that") == .duplicateThat)
        #expect(DictationCommand.parse("Duplicate that.") == .duplicateThat)
        #expect(DictationCommand.parse("duplicate it") == .duplicateThat)
        #expect(DictationCommand.parse("dupe that") == .duplicateThat)
        #expect(DictationCommand.parse("copy paste that") == .duplicateThat)
        #expect(DictationCommand.parse("please duplicate that") == .duplicateThat)
    }

    @Test("recognizes go to previous / next sentence (not select)")
    func moveSentenceCommands() {
        #expect(DictationCommand.parse("go to previous sentence") == .moveToPreviousSentence)
        #expect(DictationCommand.parse("previous sentence") == .moveToPreviousSentence)
        #expect(DictationCommand.parse("move to previous sentence") == .moveToPreviousSentence)
        #expect(DictationCommand.parse("back a sentence") == .moveToPreviousSentence)
        #expect(DictationCommand.parse("Previous sentence.") == .moveToPreviousSentence)
        #expect(DictationCommand.parse("please go to previous sentence") == .moveToPreviousSentence)

        #expect(DictationCommand.parse("go to next sentence") == .moveToNextSentence)
        #expect(DictationCommand.parse("next sentence") == .moveToNextSentence)
        #expect(DictationCommand.parse("move to next sentence") == .moveToNextSentence)
        #expect(DictationCommand.parse("forward a sentence") == .moveToNextSentence)
        #expect(DictationCommand.parse("please next sentence") == .moveToNextSentence)

        // Select phrases must not be stolen by move
        #expect(DictationCommand.parse("select previous sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("select last sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("highlight previous sentence") == .selectLastSentence)
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
        #expect(says.contains(where: { $0.lowercased().contains("sentence") }))
        #expect(says.contains(where: { $0.lowercased().contains("paragraph") }))
        #expect(says.contains(where: { $0.lowercased().contains("select last line") || $0.lowercased().contains("select line") }))
        #expect(says.contains(where: { $0.lowercased().contains("move up") || $0.lowercased().contains("line up") }))
        #expect(says.contains(where: { $0.lowercased().contains("move down") || $0.lowercased().contains("line down") }))
        #expect(says.contains(where: { $0.lowercased().contains("spell that") }))
        #expect(says.contains(where: { $0.lowercased().contains("spell as") }))
        #expect(says.contains(where: { $0.lowercased().contains("backspace") }))
        #expect(says.contains(where: { $0.lowercased().contains("move left") }))
        #expect(says.contains(where: { $0.lowercased().contains("move right") }))
        #expect(says.contains(where: { $0.lowercased().contains("bold") }))
        #expect(says.contains(where: { $0.lowercased().contains("italic") }))
        #expect(says.contains(where: { $0.lowercased().contains("underline") }))
        #expect(says.contains(where: { $0.lowercased().contains("cut that") }))
        #expect(says.contains(where: { $0.lowercased().contains("duplicate") }))
        #expect(says.contains(where: { $0.lowercased().contains("previous sentence") }))
        #expect(says.contains(where: { $0.lowercased().contains("next sentence") }))
    }

    @Test("spell as is content not a sticky command")
    func spellAsIsNotCommand() {
        #expect(DictationCommand.parse("spell as a b c") == .none)
        #expect(DictationCommand.parse("spell as capital j o h n") == .none)
        #expect(DictationCommand.parse("spell mode") == .setSpellMode(.on))
        #expect(DictationCommand.parse("spell that") == .spellThat)
    }
}
