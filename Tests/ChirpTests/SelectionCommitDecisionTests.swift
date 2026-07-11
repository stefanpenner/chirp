// SelectionCommitDecisionTests.swift — Pure gates dual of SelectionCommit.tla.

import Testing
@testable import Chirp

@Suite("SelectionCommitDecision")
struct SelectionCommitDecisionTests {

    @Test("shouldReplaceSuffix requires non-empty trailing match")
    func shouldReplace() {
        #expect(!SelectionCommitDecision.shouldReplaceSuffix(selection: nil, buffer: "Hello"))
        #expect(!SelectionCommitDecision.shouldReplaceSuffix(selection: "", buffer: "Hello"))
        #expect(!SelectionCommitDecision.shouldReplaceSuffix(selection: "Hi", buffer: "Hello"))
        #expect(SelectionCommitDecision.shouldReplaceSuffix(selection: "lo", buffer: "Hello"))
        #expect(SelectionCommitDecision.shouldReplaceSuffix(selection: "Hello", buffer: "Hello"))
        #expect(SelectionCommitDecision.shouldReplaceSuffix(selection: " world", buffer: "Hello world"))
    }

    @Test("baseAfterPeel drops trailing selection")
    func baseAfterPeel() {
        #expect(SelectionCommitDecision.baseAfterPeel(buffer: "Hello world", selection: " world") == "Hello")
        #expect(SelectionCommitDecision.baseAfterPeel(buffer: "Hello world", selection: "Hello world") == "")
        #expect(SelectionCommitDecision.baseAfterPeel(buffer: "Hello", selection: "xyz") == "Hello")
        #expect(SelectionCommitDecision.baseAfterPeel(buffer: "ab", selection: "") == "ab")
    }

    @Test("bufferAfterReplace peels then concats without inventing space")
    func bufferAfterReplace() {
        #expect(
            SelectionCommitDecision.bufferAfterReplace(
                buffer: "Hello world",
                selection: " world",
                replacement: "planet"
            ) == "Helloplanet"
        )
        #expect(
            SelectionCommitDecision.bufferAfterReplace(
                buffer: "wrong words",
                selection: "wrong words",
                replacement: "right words"
            ) == "right words"
        )
        #expect(
            SelectionCommitDecision.bufferAfterReplace(
                buffer: "one two three",
                selection: " two three",
                replacement: " four"
            ) == "one four"
        )
    }

    @Test("isInRange rejects empty and OOB windows")
    func isInRange() {
        #expect(SelectionCommitDecision.isInRange(start: 0, length: 5, bufferCount: 5))
        #expect(SelectionCommitDecision.isInRange(start: 2, length: 3, bufferCount: 5))
        #expect(!SelectionCommitDecision.isInRange(start: 0, length: 0, bufferCount: 5))
        #expect(!SelectionCommitDecision.isInRange(start: -1, length: 2, bufferCount: 5))
        #expect(!SelectionCommitDecision.isInRange(start: 3, length: 3, bufferCount: 5))
        #expect(!SelectionCommitDecision.isInRange(start: 0, length: 1, bufferCount: 0))
    }

    @Test("isTrailing only when window ends at buffer end")
    func isTrailing() {
        #expect(SelectionCommitDecision.isTrailing(start: 2, length: 3, bufferCount: 5))
        #expect(SelectionCommitDecision.isTrailing(start: 0, length: 5, bufferCount: 5))
        #expect(!SelectionCommitDecision.isTrailing(start: 0, length: 3, bufferCount: 5))
        #expect(!SelectionCommitDecision.isTrailing(start: 0, length: 0, bufferCount: 5))
    }

    @Test("bufferAfterRangeReplace splices middle and trailing")
    func bufferAfterRangeReplace() {
        // First sentence of "Hello. World now"
        let buf = "Hello. World now"
        let firstLen = "Hello.".count
        #expect(
            SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: buf,
                start: 0,
                length: firstLen,
                replacement: "Hi."
            ) == "Hi. World now"
        )
        // Second sentence
        let secondStart = "Hello. ".count
        let secondLen = "World now".count
        #expect(
            SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: buf,
                start: secondStart,
                length: secondLen,
                replacement: "Planet"
            ) == "Hello. Planet"
        )
        // Trailing word with leading space
        #expect(
            SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: "Hello world",
                start: "Hello".count,
                length: " world".count,
                replacement: "planet"
            ) == "Helloplanet"
        )
        // OOB
        #expect(
            SelectionCommitDecision.bufferAfterRangeReplace(
                buffer: "ab",
                start: 0,
                length: 5,
                replacement: "x"
            ) == nil
        )
    }
}
