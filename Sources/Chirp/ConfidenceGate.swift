// ConfidenceGate.swift — Accept/reject ASR output using token log-probs when
// available (SOTA: confidence-based rejection). When the model provides no
// scores, always accept (Parakeet TDT may leave ys_log_probs NULL).
// Length-aware: short hyps need higher mean confidence (fewer tokens → higher variance).

import Foundation

enum ConfidenceGate {
    /// Base minimum mean token log-probability (long hypotheses, 9+ tokens).
    /// Tuned conservatively: only extreme low-confidence dumps are rejected.
    /// log p = -5 ≈ p ≈ 0.0067 per token average.
    static let minMeanLogProb: Float = -5.0

    /// Stricter floors for short/medium hyps (fewer tokens → noisier mean).
    /// - 1–2 tokens: -3.0
    /// - 3–8 tokens: -4.0
    /// - 9+ tokens: `minMeanLogProb` (-5.0)
    static func minMeanLogProb(forTokenCount n: Int) -> Float {
        switch n {
        case ...2: return -3.0
        case 3...8: return -4.0
        default: return minMeanLogProb
        }
    }

    /// Whether to accept a result given optional per-token log probs.
    static func accept(tokenLogProbs: [Float]?) -> Bool {
        guard let probs = tokenLogProbs, !probs.isEmpty else {
            return true // no scores → cannot reject
        }
        let mean = probs.reduce(0, +) / Float(probs.count)
        let threshold = minMeanLogProb(forTokenCount: probs.count)
        return mean >= threshold
    }

    /// Mean log-prob for diagnostics (nil if unavailable).
    static func meanLogProb(tokenLogProbs: [Float]?) -> Float? {
        guard let probs = tokenLogProbs, !probs.isEmpty else { return nil }
        return probs.reduce(0, +) / Float(probs.count)
    }
}
