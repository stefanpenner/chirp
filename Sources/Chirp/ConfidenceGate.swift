// ConfidenceGate.swift — Accept/reject ASR output using token log-probs when
// available (SOTA: confidence-based rejection). When the model provides no
// scores, always accept (Parakeet TDT may leave ys_log_probs NULL).

import Foundation

enum ConfidenceGate {
    /// Minimum mean token log-probability to accept a hypothesis.
    /// Tuned conservatively: only extreme low-confidence dumps are rejected.
    /// log p = -5 ≈ p ≈ 0.0067 per token average.
    static let minMeanLogProb: Float = -5.0

    /// Whether to accept a result given optional per-token log probs.
    static func accept(tokenLogProbs: [Float]?) -> Bool {
        guard let probs = tokenLogProbs, !probs.isEmpty else {
            return true // no scores → cannot reject
        }
        let mean = probs.reduce(0, +) / Float(probs.count)
        return mean >= minMeanLogProb
    }

    /// Mean log-prob for diagnostics (nil if unavailable).
    static func meanLogProb(tokenLogProbs: [Float]?) -> Float? {
        guard let probs = tokenLogProbs, !probs.isEmpty else { return nil }
        return probs.reduce(0, +) / Float(probs.count)
    }
}
