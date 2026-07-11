// PhraseReplaceDecisionTests.swift — Pure gates dual of ReplacePhrase.tla.

import Testing
@testable import Chirp

@Suite("PhraseReplaceDecision")
struct PhraseReplaceDecisionTests {

    @Test("findLastRange prefers last case-insensitive match")
    func findLastRange() {
        #expect(PhraseReplaceDecision.findLastRange(target: "", in: "ab") == nil)
        #expect(PhraseReplaceDecision.findLastRange(target: "x", in: "") == nil)
        #expect(PhraseReplaceDecision.findLastRange(target: "zzz", in: "hello") == nil)

        let one = PhraseReplaceDecision.findLastRange(target: "world", in: "hello world")
        #expect(one?.start == "hello ".count)
        #expect(one?.length == "world".count)

        let multi = PhraseReplaceDecision.findLastRange(
            target: "foo",
            in: "foo bar foo"
        )
        #expect(multi?.start == "foo bar ".count)
        #expect(multi?.length == 3)

        let caseFold = PhraseReplaceDecision.findLastRange(
            target: "World",
            in: "hello WORLD end"
        )
        #expect(caseFold?.start == "hello ".count)
        #expect(caseFold?.length == "WORLD".count)
    }

    @Test("bufferAfterReplace splices last match; miss is nil")
    func bufferAfterReplace() {
        #expect(
            PhraseReplaceDecision.bufferAfterReplace(
                buffer: "hello world foo",
                target: "world",
                replacement: "planet"
            ) == "hello planet foo"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterReplace(
                buffer: "a foo b foo c",
                target: "foo",
                replacement: "bar"
            ) == "a foo b bar c"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterReplace(
                buffer: "Hello World",
                target: "hello",
                replacement: "Hi"
            ) == "Hi World"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterReplace(
                buffer: "hello world",
                target: "zzz",
                replacement: "nope"
            ) == nil
        )
    }

    @Test("findLastDeletableRange absorbs adjacent space")
    func findLastDeletableRange() {
        let mid = PhraseReplaceDecision.findLastDeletableRange(
            target: "world",
            in: "hello world foo"
        )
        #expect(mid?.start == "hello".count)
        #expect(mid?.length == " world".count)

        let trailing = PhraseReplaceDecision.findLastDeletableRange(
            target: "world",
            in: "hello world"
        )
        #expect(trailing?.start == "hello".count)
        #expect(trailing?.length == " world".count)

        let leading = PhraseReplaceDecision.findLastDeletableRange(
            target: "hello",
            in: "hello world"
        )
        #expect(leading?.start == 0)
        #expect(leading?.length == "hello ".count)
    }

    @Test("bufferAfterDelete removes last match without double spaces")
    func bufferAfterDelete() {
        #expect(
            PhraseReplaceDecision.bufferAfterDelete(
                buffer: "hello world foo",
                target: "world"
            ) == "hello foo"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterDelete(
                buffer: "a foo b foo c",
                target: "foo"
            ) == "a foo b c"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterDelete(
                buffer: "Hello World",
                target: "hello"
            ) == "World"
        )
        #expect(
            PhraseReplaceDecision.bufferAfterDelete(
                buffer: "hello world",
                target: "zzz"
            ) == nil
        )
    }
}
