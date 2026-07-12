// ParagraphMoveDecisionTests.swift — Dual of MoveParagraphsN.tla + offsetAfterParagraphMove.

import Testing
@testable import Chirp

@Suite("ParagraphMoveDecision")
struct ParagraphMoveDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(ParagraphMoveDecision.clampCount(0) == 1)
        #expect(ParagraphMoveDecision.clampCount(-2) == 1)
        #expect(ParagraphMoveDecision.clampCount(4) == 4)
        #expect(ParagraphMoveDecision.clampCount(50) == ParagraphMoveDecision.maxCount)
    }

    @Test("offsetAfterParagraphMove jumps to paragraph starts")
    func dualOffset() {
        let t = "aaa\n\nbbb\n\nccc\n\nddd"
        // paragraphs: aaa | bbb | ccc | ddd
        let ranges = TranscriptSelection.paragraphRanges(t)
        #expect(ranges.count == 4)
        // from ddd start, up 2 → bbb start
        let dddStart = ranges[3].start
        let up2 = TranscriptSelection.offsetAfterParagraphMove(
            t, caret: dddStart, up: true, count: 2
        )
        #expect(up2 == ranges[1].start)
        // from aaa start, down 2 → ccc start
        let down2 = TranscriptSelection.offsetAfterParagraphMove(
            t, caret: 0, up: false, count: 2
        )
        #expect(down2 == ranges[2].start)
        // clamp at edges
        #expect(
            TranscriptSelection.offsetAfterParagraphMove(t, caret: 0, up: true, count: 5)
                == ranges[0].start
        )
        #expect(t == "aaa\n\nbbb\n\nccc\n\nddd")
    }

    @Test("selectParagraphsSpan covers N paragraphs inclusive")
    func selectSpan() {
        let t = "aaa\n\nbbb\n\nccc\n\nddd"
        let ranges = TranscriptSelection.paragraphRanges(t)
        #expect(ranges.count == 4)
        // from ddd, select up 2 → bbb..ddd
        let up = TranscriptSelection.selectParagraphsSpan(
            t, caret: ranges[3].start, up: true, count: 2
        )
        #expect(up != nil)
        #expect(up!.start == ranges[2].start)
        #expect(up!.start + up!.length == ranges[3].end)
        // from aaa, select down 3 → aaa..ccc
        let down = TranscriptSelection.selectParagraphsSpan(
            t, caret: 0, up: false, count: 3
        )
        #expect(down != nil)
        #expect(down!.start == ranges[0].start)
        #expect(down!.start + down!.length == ranges[2].end)
        #expect(TranscriptSelection.selectParagraphsSpan(t, caret: 0, up: true, count: 0) == nil)
        #expect(TranscriptSelection.selectParagraphsSpan("", caret: 0, up: true, count: 1) == nil)
    }

    @Test("selectSentencesSpan covers N sentences inclusive")
    func selectSentenceSpan() {
        let t = "One. Two. Three. Four."
        let ranges = TranscriptSelection.sentenceRanges(t)
        #expect(ranges.count >= 3)
        let lastStart = ranges[ranges.count - 1].start
        let up = TranscriptSelection.selectSentencesSpan(
            t, caret: lastStart, up: true, count: 2
        )
        #expect(up != nil)
        #expect(up!.start == ranges[ranges.count - 2].start)
        #expect(up!.start + up!.length == ranges[ranges.count - 1].end)
        let down = TranscriptSelection.selectSentencesSpan(
            t, caret: ranges[0].start, up: false, count: 2
        )
        #expect(down != nil)
        #expect(down!.start == ranges[0].start)
        #expect(down!.start + down!.length == ranges[1].end)
        #expect(TranscriptSelection.selectSentencesSpan(t, caret: 0, up: true, count: 0) == nil)
    }
}
