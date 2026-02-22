// APIConfiguration.swift — Data models for cloud AI integration.
// Defines endpoint configuration, API keys (via Keychain), and AI settings.
// All cloud features are opt-in; offline is the default.

import Foundation

// MARK: - API Protocol

public enum APIProtocol: String, Codable, CaseIterable, Sendable {
    case openAI
    case anthropic
    case google
}

// MARK: - API Endpoint

public struct APIEndpoint: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String               // "Work OpenAI", "Personal Anthropic"
    public var apiProtocol: APIProtocol
    public var baseURL: URL               // supports gateways via custom URL
    public var apiKeyRef: String          // Keychain account name (NOT raw key)
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        apiProtocol: APIProtocol,
        baseURL: URL,
        apiKeyRef: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.isEnabled = isEnabled
    }

    /// Default base URLs per protocol.
    public static func defaultBaseURL(for proto: APIProtocol) -> URL {
        switch proto {
        case .openAI:    return URL(string: "https://api.openai.com/v1")!
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .google:    return URL(string: "https://generativelanguage.googleapis.com")!
        }
    }
}

// MARK: - Transcription & Post-Processing Modes

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case offline
    case cloud
}

public enum PostProcessingMode: String, Codable, CaseIterable, Sendable {
    case regex
    case llm
    case regexThenLLM
}

// MARK: - AI Settings

public struct AISettings: Codable, Sendable, Equatable {
    public var transcriptionMode: TranscriptionMode = .offline
    public var postProcessingMode: PostProcessingMode = .regex
    public var sttEndpointID: UUID?
    public var llmEndpointID: UUID?
    public var sttModel: String?
    public var llmModel: String?
    public var llmSystemPrompt: String?
    public var endpoints: [APIEndpoint] = []

    // MARK: Persistence

    private static let userDefaultsKey = "chirp.aiSettings"

    public static var saved: AISettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    // MARK: Endpoint Lookup

    func sttEndpoint() -> APIEndpoint? {
        guard let id = sttEndpointID else { return nil }
        return endpoints.first { $0.id == id && $0.isEnabled }
    }

    func llmEndpoint() -> APIEndpoint? {
        guard let id = llmEndpointID else { return nil }
        return endpoints.first { $0.id == id && $0.isEnabled }
    }
}
