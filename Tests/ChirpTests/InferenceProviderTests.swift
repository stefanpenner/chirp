// InferenceProviderTests.swift — Pure selection chain (CPU default).

import Testing
@testable import Chirp

@Suite("InferenceProvider")
struct InferenceProviderTests {

    @Test("default candidates prefer cpu")
    func defaultCPUFirst() {
        // Without CHIRP_ASR_PROVIDER, only cpu is in the chain
        let chosen = InferenceProvider.select(candidates: ["cpu"]) { $0 == "cpu" }
        #expect(chosen == "cpu")
        #expect(InferenceProvider.vadProvider == "cpu")
    }

    @Test("select honors explicit coreml→cpu chain")
    func explicitCoreMLChain() {
        let chosen = InferenceProvider.select(candidates: ["coreml", "cpu"]) {
            $0 == "coreml" || $0 == "cpu"
        }
        #expect(chosen == "coreml")
    }

    @Test("falls back to cpu when preferred unavailable")
    func fallbackCPU() {
        let chosen = InferenceProvider.select(candidates: ["coreml", "cpu"]) { $0 == "cpu" }
        #expect(chosen == "cpu")
    }

    @Test("defaults to cpu if nothing available")
    func defaultCPU() {
        let chosen = InferenceProvider.select(candidates: ["coreml"]) { _ in false }
        #expect(chosen == "cpu")
    }
}
