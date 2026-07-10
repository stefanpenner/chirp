// SegmentJoinerTests.swift — Pure join rules for multi-utterance commits.

import Testing
@testable import Chirp

@Suite("SegmentJoiner")
struct SegmentJoinerTests {

    @Test("first segment has no separator")
    func firstSegment() {
        let j = SegmentJoiner.append(existing: "", next: "Hello world")
        #expect(j.full == "Hello world")
        #expect(j.delta == "Hello world")
    }

    @Test("lowercase continuation gets a single space")
    func lowercaseContinuation() {
        let j = SegmentJoiner.append(existing: "Hello", next: "world")
        #expect(j.full == "Hello world")
        #expect(j.delta == " world")
    }

    @Test("uppercase after bare text inserts sentence break")
    func uppercaseNewSentence() {
        let j = SegmentJoiner.append(existing: "Hello world", next: "Create a new note.")
        #expect(j.full == "Hello world. Create a new note.")
        #expect(j.delta == ". Create a new note.")
    }

    @Test("uppercase after terminal punct uses single space")
    func afterPeriod() {
        let j = SegmentJoiner.append(existing: "Hello world.", next: "Create a note.")
        #expect(j.full == "Hello world. Create a note.")
        #expect(j.delta == " Create a note.")
    }

    @Test("empty next is a no-op")
    func emptyNext() {
        let j = SegmentJoiner.append(existing: "Hi", next: "  ")
        #expect(j.full == "Hi")
        #expect(j.delta.isEmpty)
    }

    @Test("separator helper matches append")
    func separatorHelper() {
        #expect(SegmentJoiner.separator(between: "Hi", and: "there") == " ")
        #expect(SegmentJoiner.separator(between: "Hi", and: "There") == ". ")
        #expect(SegmentJoiner.separator(between: "Hi!", and: "There") == " ")
    }
}
