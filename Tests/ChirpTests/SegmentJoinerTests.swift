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

    @Test("first segment capitalizes leading lowercase")
    func firstSegmentCapitalizes() {
        let j = SegmentJoiner.append(existing: "", next: "hello world")
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

    @Test("dict product name does not invent a period")
    func dictProductNoFalsePeriod() {
        let j = SegmentJoiner.append(existing: "please open", next: "GitHub")
        #expect(j.full == "please open GitHub")
        #expect(j.delta == " GitHub")
        #expect(!SegmentJoiner.needsSentenceBreak(existing: "please open", next: "GitHub"))
    }

    @Test("multi-word dict product prefix uses space")
    func multiWordProductNoFalsePeriod() {
        let j = SegmentJoiner.append(existing: "I use", next: "VS Code daily")
        #expect(j.full == "I use VS Code daily")
        #expect(j.delta == " VS Code daily")
    }

    @Test("single proper noun uses space not period")
    func properNounNoFalsePeriod() {
        let j = SegmentJoiner.append(existing: "I met", next: "Alice")
        #expect(j.full == "I met Alice")
        #expect(j.delta == " Alice")
    }

    @Test("CamelCase product single token uses space")
    func camelCaseProduct() {
        #expect(SegmentJoiner.separator(between: "open", and: "SwiftUI") == " ")
        #expect(SegmentJoiner.looksLikeProperContinuation("SwiftUI") == true)
    }

    @Test("real multi-word sentence still breaks")
    func realSentenceStillBreaks() {
        #expect(SegmentJoiner.needsSentenceBreak(
            existing: "Hello world",
            next: "Create a new note"
        ))
        #expect(SegmentJoiner.separator(between: "Hello world", and: "Schedule a meeting") == ". ")
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
