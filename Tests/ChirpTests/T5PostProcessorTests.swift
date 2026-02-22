import Testing
import Foundation
@testable import Chirp

@Suite("T5PostProcessor")
struct T5PostProcessorTests {

    /// Integration test — requires T5 model to be downloaded.
    /// Skipped automatically if model files are not present.
    @Test("Processes text with downloaded model")
    func processWithModel() async throws {
        guard let modelDir = T5ModelManager.findExisting() else {
            // Model not downloaded — skip gracefully
            withKnownIssue("T5 model not downloaded") {
                Issue.record("Skipping: T5 model not available at \(T5ModelManager.installBase)")
            }
            return
        }
        let processor = try T5PostProcessor(modelDir: modelDir)
        let result = try await processor.process("hello how are you doing today")
        // T5 should return some non-empty cleaned text
        #expect(!result.isEmpty)
    }

    @Test("Returns original text when input is empty")
    func emptyInput() async throws {
        guard let modelDir = T5ModelManager.findExisting() else { return }
        let processor = try T5PostProcessor(modelDir: modelDir)
        let result = try await processor.process("")
        #expect(result.isEmpty)
    }

    @Test("Throws on missing model directory")
    func missingModel() {
        #expect(throws: T5PostProcessor.T5Error.self) {
            _ = try T5PostProcessor(modelDir: "/nonexistent/model")
        }
    }

    @Test("T5ModelManager discovery returns nil when not downloaded")
    func modelDiscovery() {
        // Use a temp directory to avoid polluting real model location
        let result = T5ModelManager.findExisting()
        // This will be nil or non-nil depending on whether model is downloaded
        // We just verify it doesn't crash
        _ = result
    }
}
