// InferenceProviderTests.swift — Pure selection chain for CoreML → CPU.

import Testing
@testable import Chirp

@Suite("InferenceProvider")
struct InferenceProviderTests {

    @Test("prefers coreml when available")
    func prefersCoreML() {
        let chosen = InferenceProvider.select { $0 == "coreml" || $0 == "cpu" }
        #expect(chosen == "coreml")
    }

    @Test("falls back to cpu when coreml unavailable")
    func fallbackCPU() {
        let chosen = InferenceProvider.select { $0 == "cpu" }
        #expect(chosen == "cpu")
    }

    @Test("defaults to cpu if nothing available")
    func defaultCPU() {
        let chosen = InferenceProvider.select { _ in false }
        #expect(chosen == "cpu")
    }

    @Test("candidate order is coreml then cpu")
    func candidateOrder() {
        #expect(InferenceProvider.asrCandidates == ["coreml", "cpu"])
        #expect(InferenceProvider.vadProvider == "cpu")
    }
}
