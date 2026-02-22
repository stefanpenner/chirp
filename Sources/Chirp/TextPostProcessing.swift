// TextPostProcessing.swift — Post-processing protocol + implementations.
// Abstracts text cleanup so we can chain regex (existing) with LLM refinement.
//
// TextPostProcessing (protocol)
// +-- RegexPostProcessor       wraps existing TextPostProcessor (sub-ms)
// +-- LLMPostProcessor         sends text to an LLM for cleanup
// +-- ChainedPostProcessor     regex first, then LLM refinement

import Foundation

// MARK: - Protocol

protocol TextPostProcessing: Sendable {
    func process(_ text: String) async throws -> String
}

// MARK: - Regex (wraps existing TextPostProcessor)

struct RegexPostProcessor: TextPostProcessing {
    func process(_ text: String) async throws -> String {
        TextPostProcessor.process(text)
    }
}

// MARK: - LLM

struct LLMPostProcessor: TextPostProcessing {
    let client: any LLMClient
    let systemPrompt: String

    static let defaultSystemPrompt = """
        You are a transcription editor. Clean up the following speech-to-text output:
        - Fix grammar, punctuation, and capitalization
        - Remove filler words and false starts
        - Keep the original meaning and tone
        - Do NOT add commentary — output only the corrected text
        """

    init(client: any LLMClient, systemPrompt: String? = nil) {
        self.client = client
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
    }

    func process(_ text: String) async throws -> String {
        let result = try await client.complete(system: systemPrompt, user: text)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Chained (regex then LLM)

struct ChainedPostProcessor: TextPostProcessing {
    let regex: RegexPostProcessor
    let llm: LLMPostProcessor

    init(llm: LLMPostProcessor) {
        self.regex = RegexPostProcessor()
        self.llm = llm
    }

    func process(_ text: String) async throws -> String {
        let cleaned = try await regex.process(text)
        guard !cleaned.isEmpty else { return cleaned }
        return try await llm.process(cleaned)
    }
}
