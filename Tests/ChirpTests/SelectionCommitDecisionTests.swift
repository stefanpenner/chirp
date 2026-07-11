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
}
