// OpenAIProvider.swift — OpenAI-compatible STT (Whisper) + LLM (GPT) provider.
// Works with any OpenAI-compatible API (OpenAI, Azure, OpenRouter, local)
// by accepting a custom baseURL.

import Foundation

// MARK: - STT (Whisper API)

struct OpenAISTTClient: STTClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String = "whisper-1") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw STTError.noAPIKey }
        guard !samples.isEmpty else { throw STTError.emptyAudio }

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        let boundary = UUID().uuidString
        let url = baseURL.appendingPathComponent("audio/transcriptions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")
        // model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")
        // response_format field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("json\r\n")
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw STTError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Parse {"text": "..."}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw STTError.invalidResponse
        }

        return text
    }
}

// MARK: - LLM (Chat Completions API)

struct OpenAILLMClient: LLMClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String = "gpt-4o-mini") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        guard !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
