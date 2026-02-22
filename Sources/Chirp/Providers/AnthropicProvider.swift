// AnthropicProvider.swift — Anthropic Messages API provider (LLM only).
// Anthropic does not offer a speech-to-text API.

import Foundation

struct AnthropicLLMClient: LLMClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String = "claude-sonnet-4-6-20250514") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Parse Anthropic response: {"content": [{"type": "text", "text": "..."}]}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.invalidResponse
        }

        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
