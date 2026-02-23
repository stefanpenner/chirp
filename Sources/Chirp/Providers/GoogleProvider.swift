// GoogleProvider.swift — Google Cloud Speech-to-Text + Gemini LLM provider.

import Foundation

// MARK: - STT (Google Cloud Speech-to-Text v1)

struct GoogleSTTClient: STTClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let session: URLSession

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw STTError.noAPIKey }
        guard !samples.isEmpty else { throw STTError.emptyAudio }

        // Encode as WAV then base64
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        let audioContent = wavData.base64EncodedString()

        // Use Speech-to-Text v1 recognize endpoint
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("v1/speech:recognize"), resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": sampleRate,
                "languageCode": "en-US",
                "model": "latest_long",
            ],
            "audio": [
                "content": audioContent,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await HTTPHelper.performRequest(request, session: session) { code, body in
            STTError.httpError(statusCode: code, body: body)
        }

        let json = try HTTPHelper.parseJSON(data) { STTError.invalidResponse }

        // Parse: {"results": [{"alternatives": [{"transcript": "..."}]}]}
        guard let results = json["results"] as? [[String: Any]] else {
            throw STTError.invalidResponse
        }

        let transcript = results.compactMap { result -> String? in
            guard let alternatives = result["alternatives"] as? [[String: Any]],
                  let first = alternatives.first,
                  let text = first["transcript"] as? String else { return nil }
            return text
        }.joined(separator: " ")

        return transcript
    }
}

// MARK: - LLM (Gemini API)

struct GoogleLLMClient: LLMClient, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let session: URLSession

    init(baseURL: URL, apiKey: String, model: String = "gemini-2.0-flash", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }

        var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("v1beta/models/\(model):generateContent"),
            resolvingAgainstBaseURL: false
        )!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "system_instruction": [
                "parts": [["text": system]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": user]],
                ],
            ],
            "generationConfig": [
                "temperature": 0.3,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await HTTPHelper.performRequest(request, session: session) { code, body in
            LLMError.httpError(statusCode: code, body: body)
        }

        let json = try HTTPHelper.parseJSON(data) { LLMError.invalidResponse }

        // Parse: {"candidates": [{"content": {"parts": [{"text": "..."}]}}]}
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw LLMError.invalidResponse
        }

        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
