// ResumeWithDecisionTests.swift — Dual of specs/ResumeWith.tla.

import Testing
@testable import Chirp

@Suite("ResumeWithDecision")
struct ResumeWithDecisionTests {

    @Test("truncate after last match keeps prefix through target")
    func truncateKeepsThroughTarget() {
        let r = ResumeWithDecision.truncateAfterLastMatch(
            target: "world",
            buffer: "hello world foo bar"
        )
        #expect(r?.buffer == "hello world")
        #expect(r?.deletedCount == " foo bar".count)
        #expect(r?.caret == "hello world".count)
    }

    @Test("already trailing match deletes zero")
    func trailingMatchNoDelete() {
        let r = ResumeWithDecision.truncateAfterLastMatch(
            target: "bar",
            buffer: "hello bar"
        )
        #expect(r?.buffer == "hello bar")
        #expect(r?.deletedCount == 0)
        #expect(r?.caret == "hello bar".count)
    }

    @Test("missing target is nil")
    func missingTarget() {
        #expect(
            ResumeWithDecision.truncateAfterLastMatch(
                target: "zzz",
                buffer: "hello world"
            ) == nil
        )
    }

    @Test("empty target or buffer is nil")
    func emptyInputs() {
        #expect(
            ResumeWithDecision.truncateAfterLastMatch(target: "", buffer: "hi") == nil
        )
        #expect(
            ResumeWithDecision.truncateAfterLastMatch(target: "hi", buffer: "") == nil
        )
    }

    @Test("case-insensitive last occurrence wins")
    func caseInsensitiveLast() {
        let r = ResumeWithDecision.truncateAfterLastMatch(
            target: "World",
            buffer: "World one world two"
        )
        #expect(r?.buffer == "World one world")
        #expect(r?.deletedCount == " two".count)
    }
}
