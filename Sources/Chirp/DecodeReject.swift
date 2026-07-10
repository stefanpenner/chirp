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
    ]

    /// Reject ASR hyp when energy + text heuristics say garbage.
    ///
    /// Rules:
    /// 1. meanLogProb present and below threshold → reject
    /// 2. speechFrameCount == 0 and non-empty hyp → reject (decode on silence)
    /// 3. speechFrameCount == 0 and empty hyp → accept
    /// 4. speechFrameCount ≤ 1 and whole hyp is a known filler → reject
    /// 5. Real short words with speechFrameCount > 0 are kept (user said "ok")
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

        return false
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
