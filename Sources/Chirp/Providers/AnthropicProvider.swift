// AnthropicProvider.swift — Anthropic Messages API provider (LLM only).
// Anthropic does not offer a speech-to-text API.

import Foundation

struct AnthropicLLMClient: LLMClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let session: URLSession

    init(baseURL: URL, apiKey: String, model: String = "claude-sonnet-4-6-20250514", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }

        let url = baseURL.appendingPathComponent("v1/messages")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await HTTPHelper.performRequest(request, session: session) { code, body in
            LLMError.httpError(statusCode: code, body: body)
        }

        let json = try HTTPHelper.parseJSON(data) { LLMError.invalidResponse }

        // Parse Anthropic response: {"content": [{"type": "text", "text": "..."}]}
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.invalidResponse
        }

        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
