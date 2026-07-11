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
}
