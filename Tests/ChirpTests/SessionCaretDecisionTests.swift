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
}
