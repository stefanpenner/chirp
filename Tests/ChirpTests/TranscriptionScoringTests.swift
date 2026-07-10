// TranscriptionScoringTests.swift — Always-on unit tests for WER/CER ranking.
// No model required.

import Testing

@Suite("TranscriptionScoring")
struct TranscriptionScoringTests {

    @Test("normalize strips punctuation and case")
    func normalize() {
        #expect(TranscriptionScoring.normalize("Hello, World!") == "hello world")
        #expect(TranscriptionScoring.normalize("  A  B  ") == "a b")
        #expect(TranscriptionScoring.normalize("I'm fine.") == "i'm fine")
    }

    @Test("perfect match has zero WER and CER")
    func perfectMatch() {
        let s = TranscriptionScoring.score(
            id: "p",
            reference: "hello world",
            hypothesis: "Hello, World!"
        )
        #expect(s.wer == 0)
        #expect(s.cer == 0)
        #expect(s.wordEdits == 0)
    }

    @Test("single substitution is 1/N WER")
    func substitution() {
        let s = TranscriptionScoring.score(
            id: "s",
            reference: "the cat sat",
            hypothesis: "the dog sat"
        )
        #expect(s.wordCount == 3)
        #expect(s.wordEdits == 1)
        #expect(abs(s.wer - 1.0 / 3.0) < 1e-9)
    }

    @Test("deletion and insertion counted")
    func indel() {
        let del = TranscriptionScoring.score(id: "d", reference: "a b c", hypothesis: "a c")
        #expect(del.wordEdits == 1)
        #expect(abs(del.wer - 1.0 / 3.0) < 1e-9)

        let ins = TranscriptionScoring.score(id: "i", reference: "a c", hypothesis: "a b c")
        #expect(ins.wordEdits == 1)
        #expect(abs(ins.wer - 0.5) < 1e-9)
    }

    @Test("empty reference and empty hyp is perfect")
    func emptyBoth() {
        let s = TranscriptionScoring.score(id: "e", reference: "", hypothesis: "")
        #expect(s.wer == 0)
        #expect(s.cer == 0)
    }

    @Test("empty reference with hyp is WER 1")
    func emptyRefWithHyp() {
        let s = TranscriptionScoring.score(id: "e", reference: "", hypothesis: "noise")
        #expect(s.wer == 1)
    }

    @Test("rank orders best to worst by WER")
    func rankingOrder() {
        let ranking = TranscriptionScoring.rank([
            (id: "bad", reference: "hello world", hypothesis: "goodbye moon"),
            (id: "perfect", reference: "hello world", hypothesis: "hello world"),
            (id: "ok", reference: "hello world", hypothesis: "hello word"),
        ])
        #expect(ranking.scores.map(\.id) == ["perfect", "ok", "bad"])
        #expect(ranking.best?.id == "perfect")
        #expect(ranking.worst?.id == "bad")
        #expect(ranking.meanWER > 0)
        #expect(!ranking.leaderboard.isEmpty)
    }

    @Test("editDistance classic cases")
    func editDistance() {
        #expect(TranscriptionScoring.editDistance(Array("kitten"), Array("sitting")) == 3)
        #expect(TranscriptionScoring.editDistance(["a", "b"], ["a", "b"]) == 0)
        #expect(TranscriptionScoring.editDistance([String](), ["x"]) == 1)
    }

    @Test("number and am/pm normalization treats spoken and digit forms equal")
    func numberNormalization() {
        let s = TranscriptionScoring.score(
            id: "n",
            reference: "meeting at three pm",
            hypothesis: "meeting at 3 p.m."
        )
        #expect(s.wer == 0)
        #expect(TranscriptionScoring.normalize("three pm") == "3 pm")
    }

    @Test("majorWER ignores a/the article substitutions")
    func majorWERIgnoresArticles() {
        let s = TranscriptionScoring.score(
            id: "art",
            reference: "please send the report by friday",
            hypothesis: "please send a report by friday"
        )
        #expect(s.wer > 0)
        #expect(s.majorWER == 0)
    }

    @Test("majorWER still counts content-word errors")
    func majorWERCountsContent() {
        let s = TranscriptionScoring.score(
            id: "c",
            reference: "hello world",
            hypothesis: "hello moon"
        )
        #expect(s.majorWER > 0)
        #expect(abs(s.majorWER - 0.5) < 1e-9)
    }
}
