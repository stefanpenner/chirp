// InferenceProvider.swift — Select ONNX Runtime EP for sherpa-onnx.
// Default CPU: sherpa-onnx CoreML often underperforms multi-thread CPU for
// Parakeet int8 transducers (few ops map to ANE; CPU↔EP thrashing).
// Override with CHIRP_ASR_PROVIDER=coreml for experiments.
// Pure selection logic is dual-testable; Transcriber tries create in order.

import Foundation

enum InferenceProvider {
    /// Env var to force a preferred ASR provider (e.g. "coreml").
    static let providerEnvKey = "CHIRP_ASR_PROVIDER"

    /// Preferred provider chain for ASR.
    /// CPU first for reliable low RTF; optional CoreML via env override.
    static var asrCandidates: [String] {
        if let forced = ProcessInfo.processInfo.environment[providerEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !forced.isEmpty {
            // Forced first, then CPU as safety net
            if forced == "cpu" { return ["cpu"] }
            return [forced, "cpu"]
        }
        return ["cpu"]
    }

    /// VAD is tiny; CPU is always fine and avoids EP init cost for Silero.
    static let vadProvider = "cpu"

    /// Pick first candidate that `isAvailable` accepts.
    static func select(
        candidates: [String]? = nil,
        isAvailable: (String) -> Bool
    ) -> String {
        let list = candidates ?? asrCandidates
        for name in list where isAvailable(name) {
            return name
        }
        return "cpu"
    }
}
