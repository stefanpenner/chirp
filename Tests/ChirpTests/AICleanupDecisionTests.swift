// AICleanupDecisionTests.swift — Pure scope resolution for on-demand AI cleanup.

import Testing
@testable import Chirp

@Suite("AICleanupDecision")
struct AICleanupDecisionTests {

    @Test("empty buffer → empty")
    func emptyBuffer() {
        let scope = AICleanupDecision.resolve(
            buffer: "",
            selectionStart: nil,
            selectionLength: nil,
            lastDelta: nil
        )
        #expect(scope == .empty)
    }

    @Test("whitespace-only buffer → empty")
    func whitespaceOnly() {
        let scope = AICleanupDecision.resolve(
            buffer: "   \n",
            selectionStart: nil,
            selectionLength: nil,
            lastDelta: "  "
        )
        #expect(scope == .empty)
    }

    @Test("selection wins over last phrase")
    func selectionPreferred() {
        let buffer = "hello world there"
        // "world" at start 6, length 5
        let scope = AICleanupDecision.resolve(
            buffer: buffer,
            selectionStart: 6,
            selectionLength: 5,
            lastDelta: " there"
        )
        #expect(scope == .selection(start: 6, length: 5, text: "world"))
    }

    @Test("invalid selection falls through to last phrase")
    func invalidSelectionFallsThrough() {
        let scope = AICleanupDecision.resolve(
            buffer: "hello world",
            selectionStart: 99,
            selectionLength: 5,
            lastDelta: " world"
        )
        #expect(scope == .lastPhrase(text: " world"))
    }

    @Test("last phrase when suffix of buffer")
    func lastPhraseSuffix() {
        let scope = AICleanupDecision.resolve(
            buffer: "hello world",
            selectionStart: nil,
            selectionLength: nil,
            lastDelta: " world"
        )
        #expect(scope == .lastPhrase(text: " world"))
    }

    @Test("last phrase not suffix → full buffer")
    func lastPhraseNotSuffix() {
        let scope = AICleanupDecision.resolve(
            buffer: "hello world",
            selectionStart: nil,
            selectionLength: nil,
            lastDelta: "gone"
        )
        #expect(scope == .fullBuffer(text: "hello world"))
    }

    @Test("no last phrase → full buffer")
    func fullBufferFallback() {
        let scope = AICleanupDecision.resolve(
            buffer: "hello world",
            selectionStart: nil,
            selectionLength: nil,
            lastDelta: nil
        )
        #expect(scope == .fullBuffer(text: "hello world"))
    }

    @Test("shouldRewriteHost tracks incremental typing policy")
    func rewriteHost() {
        #expect(AICleanupDecision.shouldRewriteHost(typesIncrementally: true))
        #expect(!AICleanupDecision.shouldRewriteHost(typesIncrementally: false))
    }
}
