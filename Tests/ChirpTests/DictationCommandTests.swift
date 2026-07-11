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

    @Test("recognizes delete last sentence / previous sentence")
    func deleteLastSentenceCommands() {
        #expect(DictationCommand.parse("delete last sentence") == .deleteLastSentence)
        #expect(DictationCommand.parse("delete previous sentence") == .deleteLastSentence)
        #expect(DictationCommand.parse("delete sentence") == .deleteLastSentence)
        #expect(DictationCommand.parse("Delete last sentence.") == .deleteLastSentence)
        #expect(DictationCommand.parse("please delete previous sentence") == .deleteLastSentence)
        // Must not steal word delete or scratch
        #expect(DictationCommand.parse("delete last word") == .deleteLastWord)
        #expect(DictationCommand.parse("delete that") == .scratchThat)
    }

    @Test("recognizes delete last paragraph / previous paragraph")
    func deleteLastParagraphCommands() {
        #expect(DictationCommand.parse("delete last paragraph") == .deleteLastParagraph)
        #expect(DictationCommand.parse("delete previous paragraph") == .deleteLastParagraph)
        #expect(DictationCommand.parse("delete paragraph") == .deleteLastParagraph)
        #expect(DictationCommand.parse("Delete last paragraph.") == .deleteLastParagraph)
        #expect(DictationCommand.parse("please delete previous paragraph") == .deleteLastParagraph)
    }

    @Test("recognizes delete last line / previous line")
    func deleteLastLineCommands() {
        #expect(DictationCommand.parse("delete last line") == .deleteLastLine)
        #expect(DictationCommand.parse("delete previous line") == .deleteLastLine)
        #expect(DictationCommand.parse("delete line") == .deleteLastLine)
        #expect(DictationCommand.parse("Delete last line.") == .deleteLastLine)
        #expect(DictationCommand.parse("please delete previous line") == .deleteLastLine)
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

    @Test("recognizes press escape without bare escape")
    func pressEscape() {
        #expect(DictationCommand.parse("press escape") == .pressEscape)
        #expect(DictationCommand.parse("press esc") == .pressEscape)
        #expect(DictationCommand.parse("hit escape") == .pressEscape)
        #expect(DictationCommand.parse("escape key") == .pressEscape)
        #expect(DictationCommand.parse("Press Escape.") == .pressEscape)
        #expect(DictationCommand.parse("please press escape") == .pressEscape)
        // Bare "escape" is too aggressive — content / unclear intent
        #expect(DictationCommand.parse("escape") == .none)
        #expect(DictationCommand.parse("esc") == .none)
    }

    @Test("recognizes system undo without stealing undo that")
    func pressUndo() {
        #expect(DictationCommand.parse("system undo") == .pressUndo)
        #expect(DictationCommand.parse("press undo") == .pressUndo)
        #expect(DictationCommand.parse("undo key") == .pressUndo)
        #expect(DictationCommand.parse("app undo") == .pressUndo)
        #expect(DictationCommand.parse("command undo") == .pressUndo)
        #expect(DictationCommand.parse("System Undo.") == .pressUndo)
        #expect(DictationCommand.parse("please press undo") == .pressUndo)
        // Must not steal session-buffer undo / scratch
        #expect(DictationCommand.parse("undo that") == .scratchThat)
        #expect(DictationCommand.parse("scratch that") == .scratchThat)
        #expect(DictationCommand.parse("correct that") == .scratchThat)
        #expect(DictationCommand.parse("undo it") == .scratchThat)
    }

    @Test("recognizes system redo without stealing redo that")
    func pressRedo() {
        #expect(DictationCommand.parse("system redo") == .pressRedo)
        #expect(DictationCommand.parse("press redo") == .pressRedo)
        #expect(DictationCommand.parse("redo key") == .pressRedo)
        #expect(DictationCommand.parse("app redo") == .pressRedo)
        #expect(DictationCommand.parse("command redo") == .pressRedo)
        #expect(DictationCommand.parse("System Redo.") == .pressRedo)
        #expect(DictationCommand.parse("please press redo") == .pressRedo)
        // Must not steal EditStack redo
        #expect(DictationCommand.parse("redo that") == .redoThat)
        #expect(DictationCommand.parse("redo it") == .redoThat)
        #expect(DictationCommand.parse("restore that") == .redoThat)
        #expect(DictationCommand.parse("put it back") == .redoThat)
    }

    @Test("recognizes forward delete without stealing press delete / delete that")
    func pressForwardDelete() {
        #expect(DictationCommand.parse("forward delete") == .pressForwardDelete)
        #expect(DictationCommand.parse("press forward delete") == .pressForwardDelete)
        #expect(DictationCommand.parse("delete forward") == .pressForwardDelete)
        #expect(DictationCommand.parse("press delete forward") == .pressForwardDelete)
        #expect(DictationCommand.parse("Forward Delete.") == .pressForwardDelete)
        #expect(DictationCommand.parse("please forward delete") == .pressForwardDelete)
        // Laptop Delete stays backspace
        #expect(DictationCommand.parse("press delete") == .pressBackspace)
        #expect(DictationCommand.parse("delete key") == .pressBackspace)
        #expect(DictationCommand.parse("hit delete") == .pressBackspace)
        // Session scratch / delete-last paths unchanged
        #expect(DictationCommand.parse("delete that") == .scratchThat)
        #expect(DictationCommand.parse("delete it") == .scratchThat)
    }

    @Test("recognizes select next / previous word (keyboard)")
    func selectNextPreviousWord() {
        #expect(DictationCommand.parse("select next word") == .selectNextWord)
        #expect(DictationCommand.parse("select forward word") == .selectNextWord)
        #expect(DictationCommand.parse("Select next word.") == .selectNextWord)
        #expect(DictationCommand.parse("please select next word") == .selectNextWord)

        #expect(DictationCommand.parse("select previous word") == .selectPreviousWord)
        #expect(DictationCommand.parse("select prior word") == .selectPreviousWord)
        #expect(DictationCommand.parse("Select previous word.") == .selectPreviousWord)
        #expect(DictationCommand.parse("please select prior word") == .selectPreviousWord)

        // Buffer-based select last word stays separate
        #expect(DictationCommand.parse("select last word") == .selectLastWord)
        // Bare next/previous word stay navigation
        #expect(DictationCommand.parse("next word") == .moveRightWord)
        #expect(DictationCommand.parse("previous word") == .moveLeftWord)
    }

    @Test("recognizes delete next word (keyboard)")
    func deleteNextWord() {
        #expect(DictationCommand.parse("delete next word") == .deleteNextWord)
        #expect(DictationCommand.parse("delete forward word") == .deleteNextWord)
        #expect(DictationCommand.parse("Delete next word.") == .deleteNextWord)
        #expect(DictationCommand.parse("please delete next word") == .deleteNextWord)
        // Buffer-based delete last word stays separate
        #expect(DictationCommand.parse("delete last word") == .deleteLastWord)
        #expect(DictationCommand.parse("delete word") == .deleteLastWord)
    }

    @Test("recognizes insert date / insert time")
    func insertDateTime() {
        #expect(DictationCommand.parse("insert date") == .insertDate)
        #expect(DictationCommand.parse("insert today's date") == .insertDate)
        #expect(DictationCommand.parse("today's date") == .insertDate)
        #expect(DictationCommand.parse("insert the date") == .insertDate)
        #expect(DictationCommand.parse("Insert Date.") == .insertDate)
        #expect(DictationCommand.parse("please insert the date") == .insertDate)

        #expect(DictationCommand.parse("insert time") == .insertTime)
        #expect(DictationCommand.parse("insert the time") == .insertTime)
        #expect(DictationCommand.parse("current time") == .insertTime)
        #expect(DictationCommand.parse("Insert Time.") == .insertTime)
        #expect(DictationCommand.parse("please insert time") == .insertTime)
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
        #expect(DictationCommand.parse("cap next") == .capNext)
        #expect(DictationCommand.parse("capitalize next") == .capNext)
        #expect(DictationCommand.parse("caps next") == .capNext)
        #expect(DictationCommand.parse("capital next") == .capNext)
        #expect(DictationCommand.parse("Cap Next.") == .capNext)
        #expect(DictationCommand.parse("all caps that") == .allCapsThat)
        #expect(DictationCommand.parse("no caps that") == .noCapsThat)
        #expect(DictationCommand.parse("title case that") == .titleCaseThat)
        #expect(DictationCommand.parse("title case that phrase") == .titleCaseThat)
        #expect(DictationCommand.parse("sentence case that") == .sentenceCaseThat)
        #expect(DictationCommand.parse("no space that") == .noSpaceThat)
        #expect(DictationCommand.parse("please all caps on") == .setCapsMode(.allCaps))
        // Must not steal sticky / last-word commands
        #expect(DictationCommand.parse("caps on") == .setCapsMode(.capsOn))
        #expect(DictationCommand.parse("cap that") != .capNext)
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

    @Test("recognizes sticky no-space mode on and off")
    func noSpaceModeCommands() {
        #expect(DictationCommand.parse("no space on") == .setNoSpaceMode(.on))
        #expect(DictationCommand.parse("no spaces on") == .setNoSpaceMode(.on))
        #expect(DictationCommand.parse("compound on") == .setNoSpaceMode(.on))
        #expect(DictationCommand.parse("no space off") == .setNoSpaceMode(.off))
        #expect(DictationCommand.parse("no spaces off") == .setNoSpaceMode(.off))
        #expect(DictationCommand.parse("compound off") == .setNoSpaceMode(.off))
        #expect(DictationCommand.parse("spaces on") == .setNoSpaceMode(.off))
        #expect(DictationCommand.parse("please no space on") == .setNoSpaceMode(.on))
        #expect(DictationCommand.parse("No Space Off.") == .setNoSpaceMode(.off))
        // One-shot must not be stolen by sticky mode
        #expect(DictationCommand.parse("no space that") == .noSpaceThat)
        #expect(DictationCommand.parse("no spaces that") == .noSpaceThat)
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

    @Test("first sentence selection boundaries")
    func firstSentenceSelection() {
        #expect(TranscriptSelection.firstSentence("") == "")
        #expect(TranscriptSelection.firstSentence("Hello world") == "Hello world")
        #expect(TranscriptSelection.firstSentence("Hello. World") == "Hello.")
        #expect(TranscriptSelection.firstSentence("A. B. C") == "A.")
        #expect(TranscriptSelection.firstSentence("Wait? Next") == "Wait?")
        #expect(TranscriptSelection.firstSentence("Wow! Yes") == "Wow!")
        #expect(TranscriptSelection.firstSentence("Done.") == "Done.")
        #expect(TranscriptSelection.firstSentence("Hi. There  ") == "Hi.")
    }

    @Test("second sentence selection boundaries")
    func secondSentenceSelection() {
        #expect(TranscriptSelection.secondSentence("") == "")
        #expect(TranscriptSelection.secondSentence("Hello world") == "")
        #expect(TranscriptSelection.secondSentence("Done.") == "")
        #expect(TranscriptSelection.secondSentence("Hello. World") == "World")
        #expect(TranscriptSelection.secondSentence("Hello. World now") == "World now")
        #expect(TranscriptSelection.secondSentence("A. B. C") == "B.")
        #expect(TranscriptSelection.secondSentence("Wait? Next") == "Next")
        #expect(TranscriptSelection.secondSentence("Wow! Yes") == "Yes")
        #expect(TranscriptSelection.secondSentence("Hi. There  ") == "There  ")
        // Start offset: after first sentence + whitespace
        #expect(TranscriptSelection.secondSentenceStartOffset("") == nil)
        #expect(TranscriptSelection.secondSentenceStartOffset("Hello world") == nil)
        #expect(TranscriptSelection.secondSentenceStartOffset("Hello. World") == "Hello. ".count)
        #expect(TranscriptSelection.secondSentenceStartOffset("A. B. C") == "A. ".count)
    }

    @Test("sentenceRanges splits on punct+whitespace; content starts skip whitespace")
    func sentenceRangesBoundaries() {
        #expect(TranscriptSelection.sentenceRanges("") == [])
        #expect(TranscriptSelection.sentenceRanges("Hello world") == [
            TranscriptSelection.SentenceRange(start: 0, end: "Hello world".count)
        ])
        #expect(TranscriptSelection.sentenceRanges("Done.") == [
            TranscriptSelection.SentenceRange(start: 0, end: "Done.".count)
        ])

        // Three sentences: "A. B. C"
        let three = TranscriptSelection.sentenceRanges("A. B. C")
        #expect(three.count == 3)
        #expect(three[0] == TranscriptSelection.SentenceRange(start: 0, end: "A.".count))
        #expect(three[1] == TranscriptSelection.SentenceRange(start: "A. ".count, end: "A. B.".count))
        #expect(three[2] == TranscriptSelection.SentenceRange(start: "A. B. ".count, end: "A. B. C".count))

        // Content start of second matches secondSentenceStartOffset
        let hello = TranscriptSelection.sentenceRanges("Hello. World now")
        #expect(hello.count == 2)
        #expect(hello[0] == TranscriptSelection.SentenceRange(start: 0, end: "Hello.".count))
        #expect(hello[1].start == TranscriptSelection.secondSentenceStartOffset("Hello. World now"))
        #expect(hello[1].end == "Hello. World now".count)

        // ? and ! terminators
        let q = TranscriptSelection.sentenceRanges("Wait? Next")
        #expect(q.count == 2)
        #expect(q[0] == TranscriptSelection.SentenceRange(start: 0, end: "Wait?".count))
        #expect(q[1] == TranscriptSelection.SentenceRange(start: "Wait? ".count, end: "Wait? Next".count))
    }

    @Test("last paragraph selection boundaries")
    func lastParagraphSelection() {
        #expect(TranscriptSelection.lastParagraph("") == "")
        #expect(TranscriptSelection.lastParagraph("Hello world") == "Hello world")
        #expect(TranscriptSelection.lastParagraph("Para one\n\nPara two") == "Para two")
        #expect(TranscriptSelection.lastParagraph("Line one\nLine two") == "Line two")
        #expect(TranscriptSelection.lastParagraph("A\n\nB\n\nC") == "C")
        // Blank trailing paragraph: peel separator so delete is not a no-op
        #expect(TranscriptSelection.lastParagraph("Only\n\n") == "\n\n")
        #expect(TranscriptSelection.lastParagraph("Only\n") == "\n")
    }

    @Test("first paragraph selection boundaries")
    func firstParagraphSelection() {
        #expect(TranscriptSelection.firstParagraph("") == "")
        #expect(TranscriptSelection.firstParagraph("Hello world") == "Hello world")
        #expect(TranscriptSelection.firstParagraph("Para one\n\nPara two") == "Para one")
        #expect(TranscriptSelection.firstParagraph("Line one\nLine two") == "Line one")
        #expect(TranscriptSelection.firstParagraph("A\n\nB\n\nC") == "A")
        #expect(TranscriptSelection.firstParagraph("Only\n\n") == "Only")
        #expect(TranscriptSelection.firstParagraph("Only\n") == "Only")
    }

    @Test("second paragraph selection boundaries")
    func secondParagraphSelection() {
        #expect(TranscriptSelection.secondParagraph("") == "")
        #expect(TranscriptSelection.secondParagraph("Hello world") == "")
        #expect(TranscriptSelection.secondParagraph("Para one\n\nPara two") == "Para two")
        #expect(TranscriptSelection.secondParagraph("Line one\nLine two") == "Line two")
        #expect(TranscriptSelection.secondParagraph("A\n\nB\n\nC") == "B")
        #expect(TranscriptSelection.secondParagraph("Only\n\n") == "")
        #expect(TranscriptSelection.secondParagraphStartOffset("") == nil)
        #expect(TranscriptSelection.secondParagraphStartOffset("Hello world") == nil)
        #expect(TranscriptSelection.secondParagraphStartOffset("Para one\n\nPara two") == "Para one\n\n".count)
        #expect(TranscriptSelection.secondParagraphStartOffset("Line one\nLine two") == "Line one\n".count)
    }

    @Test("paragraph ranges cover all paragraphs")
    func paragraphRanges() {
        #expect(TranscriptSelection.paragraphRanges("") == [])
        let single = TranscriptSelection.paragraphRanges("Hello world")
        #expect(single.count == 1)
        #expect(single[0] == TranscriptSelection.SentenceRange(start: 0, end: "Hello world".count))

        let two = TranscriptSelection.paragraphRanges("Para one\n\nPara two")
        #expect(two.count == 2)
        #expect(two[0] == TranscriptSelection.SentenceRange(start: 0, end: "Para one".count))
        #expect(two[1] == TranscriptSelection.SentenceRange(
            start: "Para one\n\n".count,
            end: "Para one\n\nPara two".count
        ))

        let three = TranscriptSelection.paragraphRanges("A\n\nB\n\nC")
        #expect(three.count == 3)
        #expect(three[0] == TranscriptSelection.SentenceRange(start: 0, end: 1))
        #expect(three[1] == TranscriptSelection.SentenceRange(start: "A\n\n".count, end: "A\n\nB".count))
        #expect(three[2] == TranscriptSelection.SentenceRange(
            start: "A\n\nB\n\n".count,
            end: "A\n\nB\n\nC".count
        ))

        let lines = TranscriptSelection.paragraphRanges("Line one\nLine two\nLine three")
        #expect(lines.count == 3)
        #expect(lines[0].end == "Line one".count)
        #expect(lines[1].start == "Line one\n".count)
        #expect(lines[2].start == "Line one\nLine two\n".count)
    }

    @Test("recognizes select first sentence")
    func selectFirstSentenceCommands() {
        #expect(DictationCommand.parse("select first sentence") == .selectFirstSentence)
        #expect(DictationCommand.parse("select the first sentence") == .selectFirstSentence)
        #expect(DictationCommand.parse("Select first sentence.") == .selectFirstSentence)
        #expect(DictationCommand.parse("please select the first sentence") == .selectFirstSentence)
        #expect(DictationCommand.parse("highlight first sentence") == .selectFirstSentence)
        // Post-process ITN rewrites first → 1st before command parse
        #expect(DictationCommand.parse("select 1st sentence") == .selectFirstSentence)
        #expect(DictationCommand.parse("select the 1st sentence") == .selectFirstSentence)
        #expect(DictationCommand.parse("highlight 1st sentence") == .selectFirstSentence)
    }

    @Test("recognizes select next sentence (not move next / select last)")
    func selectNextSentenceCommands() {
        #expect(DictationCommand.parse("select next sentence") == .selectNextSentence)
        #expect(DictationCommand.parse("select forward sentence") == .selectNextSentence)
        #expect(DictationCommand.parse("Select next sentence.") == .selectNextSentence)
        #expect(DictationCommand.parse("please select next sentence") == .selectNextSentence)
        #expect(DictationCommand.parse("highlight next sentence") == .selectNextSentence)
        #expect(DictationCommand.parse("highlight forward sentence") == .selectNextSentence)
        // Do not steal move / select last
        #expect(DictationCommand.parse("next sentence") == .moveToNextSentence)
        #expect(DictationCommand.parse("select last sentence") == .selectLastSentence)
        #expect(DictationCommand.parse("select previous sentence") == .selectLastSentence)
    }

    @Test("recognizes delete next sentence (not delete last / previous)")
    func deleteNextSentenceCommands() {
        #expect(DictationCommand.parse("delete next sentence") == .deleteNextSentence)
        #expect(DictationCommand.parse("delete forward sentence") == .deleteNextSentence)
        #expect(DictationCommand.parse("Delete next sentence.") == .deleteNextSentence)
        #expect(DictationCommand.parse("please delete next sentence") == .deleteNextSentence)
        #expect(DictationCommand.parse("remove next sentence") == .deleteNextSentence)
        #expect(DictationCommand.parse("remove forward sentence") == .deleteNextSentence)
        // Do not steal delete last / previous
        #expect(DictationCommand.parse("delete last sentence") == .deleteLastSentence)
        #expect(DictationCommand.parse("delete previous sentence") == .deleteLastSentence)
        #expect(DictationCommand.parse("delete sentence") == .deleteLastSentence)
    }

    @Test("recognizes select first paragraph")
    func selectFirstParagraphCommands() {
        #expect(DictationCommand.parse("select first paragraph") == .selectFirstParagraph)
        #expect(DictationCommand.parse("select the first paragraph") == .selectFirstParagraph)
        #expect(DictationCommand.parse("Select first paragraph.") == .selectFirstParagraph)
        #expect(DictationCommand.parse("please select the first paragraph") == .selectFirstParagraph)
        #expect(DictationCommand.parse("highlight first paragraph") == .selectFirstParagraph)
        // Post-process ITN rewrites first → 1st before command parse
        #expect(DictationCommand.parse("select 1st paragraph") == .selectFirstParagraph)
        #expect(DictationCommand.parse("select the 1st paragraph") == .selectFirstParagraph)
        #expect(DictationCommand.parse("highlight 1st paragraph") == .selectFirstParagraph)
    }

    @Test("recognizes select next paragraph (not select last)")
    func selectNextParagraphCommands() {
        #expect(DictationCommand.parse("select next paragraph") == .selectNextParagraph)
        #expect(DictationCommand.parse("select forward paragraph") == .selectNextParagraph)
        #expect(DictationCommand.parse("Select next paragraph.") == .selectNextParagraph)
        #expect(DictationCommand.parse("please select next paragraph") == .selectNextParagraph)
        #expect(DictationCommand.parse("highlight next paragraph") == .selectNextParagraph)
        #expect(DictationCommand.parse("highlight forward paragraph") == .selectNextParagraph)
        #expect(DictationCommand.parse("select last paragraph") == .selectLastParagraph)
        #expect(DictationCommand.parse("select previous paragraph") == .selectLastParagraph)
    }

    @Test("last line selection boundaries (content after last \\n, no leading separator)")
    func lastLineSelection() {
        #expect(TranscriptSelection.lastLine("") == "")
        #expect(TranscriptSelection.lastLine("Hello world") == "Hello world")
        #expect(TranscriptSelection.lastLine("Line one\nLine two") == "Line two")
        #expect(TranscriptSelection.lastLine("A\nB\nC") == "C")
        #expect(TranscriptSelection.lastLine("Para one\n\nPara two") == "Para two")
        // Trailing empty line: include the newline so delete peels it
        #expect(TranscriptSelection.lastLine("Only\n") == "\n")
        #expect(TranscriptSelection.lastLine("Only\n\n") == "\n")
        #expect(TranscriptSelection.lastLine("Hello.\n") == "\n")
    }

    @Test("first line selection boundaries (content before first \\n)")
    func firstLineSelection() {
        #expect(TranscriptSelection.firstLine("") == "")
        #expect(TranscriptSelection.firstLine("Hello world") == "Hello world")
        #expect(TranscriptSelection.firstLine("Line one\nLine two") == "Line one")
        #expect(TranscriptSelection.firstLine("A\nB\nC") == "A")
        #expect(TranscriptSelection.firstLine("Para one\n\nPara two") == "Para one")
        // Leading newline: empty first line
        #expect(TranscriptSelection.firstLine("\nLine two") == "")
        #expect(TranscriptSelection.firstLine("\n") == "")
        // last line still works (regression)
        #expect(TranscriptSelection.lastLine("Line one\nLine two") == "Line two")
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

    @Test("recognizes select first line (not select last line)")
    func selectFirstLineCommands() {
        #expect(DictationCommand.parse("select first line") == .selectFirstLine)
        #expect(DictationCommand.parse("select the first line") == .selectFirstLine)
        #expect(DictationCommand.parse("Select first line.") == .selectFirstLine)
        #expect(DictationCommand.parse("please select the first line") == .selectFirstLine)
        #expect(DictationCommand.parse("highlight first line") == .selectFirstLine)
        #expect(DictationCommand.parse("highlight the first line") == .selectFirstLine)
        // "first" → "1st" via SpokenNumberITN before parse
        #expect(DictationCommand.parse("select 1st line") == .selectFirstLine)
        #expect(DictationCommand.parse("select the 1st line") == .selectFirstLine)
        #expect(DictationCommand.parse("highlight 1st line") == .selectFirstLine)
        // last line phrases still map to last (regression)
        #expect(DictationCommand.parse("select last line") == .selectLastLine)
        #expect(DictationCommand.parse("select line") == .selectLastLine)
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

    @Test("recognizes move to document start/end (not line start)")
    func moveDocumentEdgeCommands() {
        #expect(DictationCommand.parse("beginning of document") == .moveToDocumentStart)
        #expect(DictationCommand.parse("top of document") == .moveToDocumentStart)
        #expect(DictationCommand.parse("go to top of document") == .moveToDocumentStart)
        #expect(DictationCommand.parse("start of document") == .moveToDocumentStart)
        #expect(DictationCommand.parse("go to beginning of document") == .moveToDocumentStart)
        #expect(DictationCommand.parse("Beginning of document.") == .moveToDocumentStart)
        #expect(DictationCommand.parse("please go to top of document") == .moveToDocumentStart)

        #expect(DictationCommand.parse("end of document") == .moveToDocumentEnd)
        #expect(DictationCommand.parse("bottom of document") == .moveToDocumentEnd)
        #expect(DictationCommand.parse("go to end of document") == .moveToDocumentEnd)
        #expect(DictationCommand.parse("go to bottom of document") == .moveToDocumentEnd)
        #expect(DictationCommand.parse("please end of document") == .moveToDocumentEnd)

        // Line-edge phrases stay line-edge
        #expect(DictationCommand.parse("go to beginning") == .moveToStart)
        #expect(DictationCommand.parse("go to start") == .moveToStart)
        #expect(DictationCommand.parse("go to end") == .moveToEnd)
    }

    @Test("recognizes page up/down scroll (not move up/down line)")
    func pageScrollCommands() {
        #expect(DictationCommand.parse("page up") == .pageUp)
        #expect(DictationCommand.parse("scroll up") == .pageUp)
        #expect(DictationCommand.parse("scroll page up") == .pageUp)
        #expect(DictationCommand.parse("Page up.") == .pageUp)
        #expect(DictationCommand.parse("please page up") == .pageUp)

        #expect(DictationCommand.parse("page down") == .pageDown)
        #expect(DictationCommand.parse("scroll down") == .pageDown)
        #expect(DictationCommand.parse("scroll page down") == .pageDown)
        #expect(DictationCommand.parse("please scroll down") == .pageDown)

        // Line moves stay separate
        #expect(DictationCommand.parse("move up") == .moveUpLine)
        #expect(DictationCommand.parse("move down") == .moveDownLine)
        #expect(DictationCommand.parse("go up") == .moveUpLine)
        #expect(DictationCommand.parse("go down") == .moveDownLine)
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
        #expect(says.contains(where: { $0.lowercased().contains("select first line") }))
        #expect(says.contains(where: { $0.lowercased().contains("delete last sentence") || $0.lowercased().contains("delete sentence") }))
        #expect(says.contains(where: { $0.lowercased().contains("delete last paragraph") || $0.lowercased().contains("delete paragraph") }))
        #expect(says.contains(where: { $0.lowercased().contains("delete last line") || $0.lowercased().contains("delete line") }))
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
        #expect(says.contains(where: { $0.lowercased().contains("document") }))
        #expect(says.contains(where: { $0.lowercased().contains("page up") || $0.lowercased().contains("scroll up") }))
        #expect(says.contains(where: { $0.lowercased().contains("page down") || $0.lowercased().contains("scroll down") }))
        #expect(says.contains(where: { $0.lowercased().contains("insert date") }))
        #expect(says.contains(where: { $0.lowercased().contains("insert time") }))
        #expect(says.contains(where: { $0.lowercased().contains("escape") || $0.lowercased().contains("esc") }))
        #expect(says.contains(where: { $0.lowercased().contains("system undo") || $0.lowercased().contains("press undo") }))
        #expect(says.contains(where: { $0.lowercased().contains("system redo") || $0.lowercased().contains("press redo") }))
        #expect(says.contains(where: { $0.lowercased().contains("forward delete") }))
        #expect(says.contains(where: { $0.lowercased().contains("select next word") }))
        #expect(says.contains(where: { $0.lowercased().contains("select previous word") || $0.lowercased().contains("select prior word") }))
        #expect(says.contains(where: { $0.lowercased().contains("delete next word") }))
        #expect(says.contains(where: { $0.lowercased().contains("select next sentence") }))
        #expect(says.contains(where: { $0.lowercased().contains("delete next sentence") }))
        #expect(says.contains(where: { $0.lowercased().contains("select next paragraph") }))
    }

    @Test("spell as is content not a sticky command")
    func spellAsIsNotCommand() {
        #expect(DictationCommand.parse("spell as a b c") == .none)
        #expect(DictationCommand.parse("spell as capital j o h n") == .none)
        #expect(DictationCommand.parse("spell mode") == .setSpellMode(.on))
        #expect(DictationCommand.parse("spell that") == .spellThat)
    }
}
