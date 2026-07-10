// InferenceProvider.swift — Select ONNX Runtime EP for sherpa-onnx.
// Prefer CoreML on Apple Silicon for lower latency / power; fall back to CPU.
// Pure selection logic is dual-testable; Transcriber tries create in order.

import Foundation

enum InferenceProvider {
    /// Preferred provider chain for ASR (and optionally VAD).
    /// CoreML uses Apple Neural Engine when the ORT build includes the EP.
    static let asrCandidates = ["coreml", "cpu"]

    /// VAD is tiny; CPU is always fine and avoids EP init cost for Silero.
    static let vadProvider = "cpu"

    /// Pick first candidate that `isAvailable` accepts.
    static func select(
        candidates: [String] = asrCandidates,
        isAvailable: (String) -> Bool
    ) -> String {
        for name in candidates where isAvailable(name) {
            return name
        }
        return "cpu"
    }
}
