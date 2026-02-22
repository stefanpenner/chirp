// CloudLLM.swift — LLM client protocol for cloud-based text completion.
// Concrete implementations live in Providers/.

import Foundation

// MARK: - Protocol

protocol LLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case noAPIKey
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidResponse: return "Invalid response from API"
        case .emptyResponse: return "Empty response from API"
        }
    }
}
