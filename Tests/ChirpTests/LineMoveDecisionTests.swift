// LineMoveDecisionTests.swift — Dual of specs/MoveLinesN.tla + offsetAfterLineMove.

import Testing
@testable import Chirp

@Suite("LineMoveDecision")
struct LineMoveDecisionTests {

    @Test("clampCount bounds to 1...maxCount")
    func clamp() {
        #expect(LineMoveDecision.clampCount(0) == 1)
        #expect(LineMoveDecision.clampCount(-1) == 1)
        #expect(LineMoveDecision.clampCount(3) == 3)
        #expect(LineMoveDecision.clampCount(100) == LineMoveDecision.maxCount)
    }

    @Test("offsetAfterLineMove count 2 steps two lines without changing buffer")
    func dualOffsetMultiLine() {
        let t = "aaa\nbbb\nccc\nddd"
        // caret at start of ddd (line 3)
        let caret = 12 // "aaa\nbbb\nccc\n" = 12
        #expect(t.count == 15)
        let up2 = TranscriptSelection.offsetAfterLineMove(t, caret: caret, up: true, count: 2)
        // two lines up from ddd → bbb start
        #expect(up2 == 4) // after "aaa\n"
        let down2 = TranscriptSelection.offsetAfterLineMove(t, caret: 0, up: false, count: 2)
        // from aaa start down 2 → ccc start
        #expect(down2 == 8) // after "aaa\nbbb\n"
        // buffer identity preserved (pure function)
        #expect(t == "aaa\nbbb\nccc\nddd")
    }

    @Test("select lines clamp matches move lines (SelectLinesN dual)")
    func selectLinesClamp() {
        #expect(LineMoveDecision.clampCount(3) == 3)
        #expect(LineMoveDecision.clampCount(0) == 1)
        #expect(LineMoveDecision.clampCount(100) == LineMoveDecision.maxCount)
    }
}
