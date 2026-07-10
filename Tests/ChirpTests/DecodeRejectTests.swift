// DecodeRejectTests.swift — Energy/silence composite reject gate.

import Testing
@testable import Chirp

@Suite("DecodeReject")
struct DecodeRejectTests {

    // MARK: - Log-prob rule

    @Test("low meanLogProb rejects regardless of energy")
    func lowMeanRejects() {
        #expect(DecodeReject.shouldReject(
            hyp: "hello",
            meanLogProb: -10,
            speechFrameCount: 5
        ))
        #expect(DecodeReject.shouldReject(
            hyp: "",
            meanLogProb: -5.1,
            speechFrameCount: 0
        ))
    }

    @Test("healthy meanLogProb with speech accepts")
    func healthyMeanAccepts() {
        #expect(!DecodeReject.shouldReject(
            hyp: "hello",
            meanLogProb: -0.5,
            speechFrameCount: 5
        ))
        #expect(!DecodeReject.shouldReject(
            hyp: "ok",
            meanLogProb: ConfidenceGate.minMeanLogProb,
            speechFrameCount: 2
        ))
    }

    // MARK: - Pure silence

    @Test("pure silence non-empty hyp rejects even without scores")
    func silenceNonEmptyRejects() {
        #expect(DecodeReject.shouldReject(
            hyp: "yeah",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
        #expect(DecodeReject.shouldReject(
            hyp: "hello world",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
        #expect(DecodeReject.shouldReject(
            hyp: "  ok  ",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
    }

    @Test("pure silence empty hyp accepts")
    func silenceEmptyAccepts() {
        #expect(!DecodeReject.shouldReject(
            hyp: "",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
        #expect(!DecodeReject.shouldReject(
            hyp: "   ",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
    }

    // MARK: - Real short words with speech

    @Test("short real words with speech frames accept")
    func shortWordsWithSpeechAccept() {
        #expect(!DecodeReject.shouldReject(
            hyp: "ok",
            meanLogProb: nil,
            speechFrameCount: 2
        ))
        #expect(!DecodeReject.shouldReject(
            hyp: "hi",
            meanLogProb: nil,
            speechFrameCount: 3
        ))
        // "yeah" with real speech (frames > 1) is kept
        #expect(!DecodeReject.shouldReject(
            hyp: "yeah",
            meanLogProb: nil,
            speechFrameCount: 2
        ))
    }

    // MARK: - Low-energy filler

    @Test("known fillers on one speech frame reject")
    func fillerOneFrameRejects() {
        for word in [
            "yeah", "yes", "you", "the", "a", "um", "uh", "Yeah", "UM",
            "ok", "okay", "hi", "bye", "hmm", "mhm", "OK", "Hi", "Bye",
        ] {
            #expect(
                DecodeReject.shouldReject(
                    hyp: word,
                    meanLogProb: nil,
                    speechFrameCount: 1
                ),
                "expected reject for filler \"\(word)\""
            )
        }
    }

    @Test("known fillers on zero frames reject via silence rule")
    func fillerZeroFramesRejects() {
        #expect(DecodeReject.shouldReject(
            hyp: "um",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
        #expect(DecodeReject.shouldReject(
            hyp: "ok",
            meanLogProb: nil,
            speechFrameCount: 0
        ))
    }

    @Test("multi-word hyp is not filler even on one frame")
    func multiWordNotFiller() {
        #expect(!DecodeReject.shouldReject(
            hyp: "yeah sure",
            meanLogProb: nil,
            speechFrameCount: 1
        ))
    }

    @Test("non-filler short word on one frame accepts")
    func nonFillerOneFrameAccepts() {
        #expect(!DecodeReject.shouldReject(
            hyp: "no",
            meanLogProb: nil,
            speechFrameCount: 1
        ))
        #expect(!DecodeReject.shouldReject(
            hyp: "cat",
            meanLogProb: nil,
            speechFrameCount: 1
        ))
    }

    @Test("new low-energy fillers accept when speech frames > 1")
    func newFillersWithSpeechAccept() {
        for word in ["ok", "okay", "hi", "bye", "hmm", "mhm"] {
            #expect(
                !DecodeReject.shouldReject(
                    hyp: word,
                    meanLogProb: nil,
                    speechFrameCount: 2
                ),
                "expected accept for \"\(word)\" with speech frames"
            )
        }
    }

    // MARK: - isLowEnergyFiller

    @Test("isLowEnergyFiller matches whole hyp only")
    func fillerHelper() {
        #expect(DecodeReject.isLowEnergyFiller("yeah"))
        #expect(DecodeReject.isLowEnergyFiller("  Yes  "))
        #expect(DecodeReject.isLowEnergyFiller("ok"))
        #expect(DecodeReject.isLowEnergyFiller("okay"))
        #expect(DecodeReject.isLowEnergyFiller("hi"))
        #expect(DecodeReject.isLowEnergyFiller("bye"))
        #expect(DecodeReject.isLowEnergyFiller("hmm"))
        #expect(DecodeReject.isLowEnergyFiller("mhm"))
        #expect(!DecodeReject.isLowEnergyFiller(""))
        #expect(!DecodeReject.isLowEnergyFiller("no"))
        #expect(!DecodeReject.isLowEnergyFiller("yeah sure"))
    }
}
