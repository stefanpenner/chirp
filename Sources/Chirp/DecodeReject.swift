// DecodeReject.swift — Energy/silence composite reject gate for ASR output.
// Complements ConfidenceGate: when token log-probs are nil (common for Parakeet),
// still reject garbage hyps produced on pure silence or near-silence padding.

import Foundation

enum DecodeReject {
    /// Whole-hypothesis fillers commonly hallucinated on silence / near-silence.
    /// Applied only when speechFrameCount ≤ 1 (conservative).
    static let lowEnergyFillers: Set<String> = [
        "yeah", "yes", "you", "the", "a", "um", "uh",
        // Short greetings/closings common on near-silence (frames ≤ 1 only)
        "ok", "okay", "hi", "bye", "hmm", "mhm",
        // Vocalizations / filler noises (not bare "no"/"so"/"like" — real short speech)
        "ah", "oh", "er", "mm", "huh",
    ]

    /// Max energy frames for multi-word nil-score silence dumps.
    /// Parakeet often omits log-probs; multi-token hyps on ≤ this many frames
    /// are typical padding hallucinations ("thank you for watching").
    static let multiWordLowEnergyMaxFrames: Int = 2

    /// Reject ASR hyp when energy + text heuristics say garbage.
    ///
    /// Rules:
    /// 1. meanLogProb present and below threshold → reject
    /// 2. speechFrameCount == 0 and non-empty hyp → reject (decode on silence)
    /// 3. speechFrameCount == 0 and empty hyp → accept
    /// 4. speechFrameCount ≤ 1 and whole hyp is a known filler → reject
    /// 5. multi-word (≥2 tokens) + nil scores + frames ≤ multiWordLowEnergyMaxFrames → reject
    /// 6. Real short words with speechFrameCount > 0 are kept (user said "ok")
    /// Dual: specs/DecodeReject.tla
    static func shouldReject(
        hyp: String,
        meanLogProb: Float?,
        speechFrameCount: Int,
        minMeanLogProb: Float = ConfidenceGate.minMeanLogProb
    ) -> Bool {
        if let mean = meanLogProb, mean < minMeanLogProb {
            return true
        }

        let trimmed = hyp.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechFrameCount == 0 {
            return !trimmed.isEmpty
        }

        if speechFrameCount <= 1, isLowEnergyFiller(trimmed) {
            return true
        }

        // Nil scores (common Parakeet): multi-word on near-silence is garbage.
        // Keep when scores exist (even low frames) or single-token short speech.
        if meanLogProb == nil,
           speechFrameCount <= multiWordLowEnergyMaxFrames,
           tokenCount(trimmed) >= 2
        {
            return true
        }

        return false
    }

    /// Whitespace-separated token count (empty → 0).
    static func tokenCount(_ hyp: String) -> Int {
        let trimmed = hyp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Case-insensitive whole-hyp match against the filler set.
    static func isLowEnergyFiller(_ hyp: String) -> Bool {
        let trimmed = hyp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Whole hyp only (not multi-word phrases).
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 1 else { return false }
        return lowEnergyFillers.contains(tokens[0].lowercased())
    }
}
