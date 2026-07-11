// SessionCaretDecisionTests.swift — Pure mid-buffer insert dual of GoToPhrase caret Commit.

import Testing
@testable import Chirp

@Suite("SessionCaretDecision")
struct SessionCaretDecisionTests {

    @Test("isMidBuffer rejects nil, end, and OOB")
    func isMidBuffer() {
        #expect(!SessionCaretDecision.isMidBuffer(caret: nil, bufferCount: 5))
        #expect(!SessionCaretDecision.isMidBuffer(caret: 5, bufferCount: 5))
        #expect(!SessionCaretDecision.isMidBuffer(caret: -1, bufferCount: 5))
        #expect(SessionCaretDecision.isMidBuffer(caret: 0, bufferCount: 5))
        #expect(SessionCaretDecision.isMidBuffer(caret: 3, bufferCount: 5))
    }

    @Test("insert after word leaves space and mid order")
    func insertAfterWord() {
        let buf = "hello world foo"
        let caret = "hello world".count
        let r = SessionCaretDecision.bufferAfterInsert(
            buffer: buf,
            caret: caret,
            piece: "planet"
        )
        #expect(r?.text == "hello world planet foo")
        #expect(r?.delta == " planet")
        #expect(r?.caret == "hello world planet".count)
    }

    @Test("insert before word adds space before remainder")
    func insertBeforeWord() {
        let buf = "hello world foo"
        let caret = "hello ".count
        let r = SessionCaretDecision.bufferAfterInsert(
            buffer: buf,
            caret: caret,
            piece: "planet"
        )
        // left "hello " + planet + right "world foo"
        #expect(r != nil)
        let text = r!.text
        #expect(text == "hello planet world foo")
        #expect(text.contains("planet"))
        #expect(text.contains("world"))
        #expect(r!.caret == "hello planet ".count || r!.caret == "hello planet".count)
    }

    @Test("insert at end is like trailing append")
    func insertAtEnd() {
        let buf = "hello world"
        let r = SessionCaretDecision.bufferAfterInsert(
            buffer: buf,
            caret: buf.count,
            piece: "foo"
        )
        #expect(r?.text == "hello world foo")
        #expect(r?.delta == " foo")
    }

    @Test("insert at empty buffer")
    func insertEmpty() {
        let r = SessionCaretDecision.bufferAfterInsert(
            buffer: "",
            caret: 0,
            piece: "hello"
        )
        #expect(r?.text == "Hello" || r?.text == "hello")
        #expect(r?.caret == r?.text.count)
    }

    @Test("OOB caret is nil")
    func oob() {
        #expect(
            SessionCaretDecision.bufferAfterInsert(
                buffer: "ab",
                caret: 5,
                piece: "x"
            ) == nil
        )
    }

    // MARK: - Host from (HostCaret dual)

    @Test("hostFrom prefers unit anchor over sessionCaret")
    func hostFromUnitWins() {
        #expect(
            SessionCaretDecision.hostFrom(
                bufferCount: 20,
                sessionCaret: 5,
                unitAnchor: 12
            ) == 12
        )
    }

    @Test("hostFrom uses sessionCaret when no unit nav")
    func hostFromSessionCaret() {
        #expect(
            SessionCaretDecision.hostFrom(
                bufferCount: 20,
                sessionCaret: 7,
                unitAnchor: nil
            ) == 7
        )
    }

    @Test("hostFrom defaults to end when caret and unit nil")
    func hostFromEndDefault() {
        #expect(
            SessionCaretDecision.hostFrom(
                bufferCount: 15,
                sessionCaret: nil,
                unitAnchor: nil
            ) == 15
        )
    }

    @Test("hostFrom clamps unit and caret into buffer")
    func hostFromClamps() {
        #expect(
            SessionCaretDecision.hostFrom(
                bufferCount: 10,
                sessionCaret: 99,
                unitAnchor: nil
            ) == 10
        )
        #expect(
            SessionCaretDecision.hostFrom(
                bufferCount: 10,
                sessionCaret: nil,
                unitAnchor: -3
            ) == 0
        )
    }

    @Test("moveDelta is to minus from")
    func moveDeltaSign() {
        #expect(SessionCaretDecision.moveDelta(from: 10, to: 3) == -7)
        #expect(SessionCaretDecision.moveDelta(from: 3, to: 10) == 7)
        #expect(SessionCaretDecision.moveDelta(from: 5, to: 5) == 0)
    }

    @Test("two successive go-to deltas use prior caret not end")
    func successiveGoToDeltas() {
        // "alpha beta gamma" — go to beta (6) from end (16), then go to alpha (0) from 6.
        let buf = "alpha beta gamma"
        let end = buf.count
        let beta = 6
        let alpha = 0
        let d1 = SessionCaretDecision.moveDelta(
            from: SessionCaretDecision.hostFrom(
                bufferCount: end, sessionCaret: nil, unitAnchor: nil
            ),
            to: beta
        )
        #expect(d1 == beta - end)
        let d2 = SessionCaretDecision.moveDelta(
            from: SessionCaretDecision.hostFrom(
                bufferCount: end, sessionCaret: beta, unitAnchor: nil
            ),
            to: alpha
        )
        #expect(d2 == alpha - beta)
        // Bug if second move assumed end: would be alpha - end, not alpha - beta.
        #expect(d2 != alpha - end)
    }
}
