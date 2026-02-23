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
    case none
    case regex
    case llm
    case regexThenLLM
    case offlineLLM
    case regexThenOfflineLLM
}

// MARK: - AI Mode (named pipeline preset)

public struct AIMode: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var transcriptionMode: TranscriptionMode
    public var postProcessingMode: PostProcessingMode
    public var sttEndpointID: UUID?
    public var sttModel: String?
    public var llmEndpointID: UUID?
    public var llmModel: String?
    public var llmSystemPrompt: String?

    public init(
        id: UUID = UUID(),
        name: String,
        transcriptionMode: TranscriptionMode = .offline,
        postProcessingMode: PostProcessingMode = .regex,
        sttEndpointID: UUID? = nil,
        sttModel: String? = nil,
        llmEndpointID: UUID? = nil,
        llmModel: String? = nil,
        llmSystemPrompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transcriptionMode = transcriptionMode
        self.postProcessingMode = postProcessingMode
        self.sttEndpointID = sttEndpointID
        self.sttModel = sttModel
        self.llmEndpointID = llmEndpointID
        self.llmModel = llmModel
        self.llmSystemPrompt = llmSystemPrompt
    }

    public static let defaults: [AIMode] = [
        AIMode(name: "Offline", transcriptionMode: .offline, postProcessingMode: .regex),
        AIMode(name: "Offline + Fixup", transcriptionMode: .offline, postProcessingMode: .regexThenOfflineLLM),
    ]
}

// MARK: - AI Settings

public struct AISettings: Codable, Sendable, Equatable {
    public var endpoints: [APIEndpoint]
    public var modes: [AIMode]
    public var activeModeID: UUID?

    public init() {
        self.endpoints = []
        self.modes = AIMode.defaults
        self.activeModeID = AIMode.defaults.first?.id
    }

    // Custom decoder for backward compatibility with old flat settings
    private enum CodingKeys: String, CodingKey {
        case endpoints, modes, activeModeID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoints = (try? c.decode([APIEndpoint].self, forKey: .endpoints)) ?? []
        modes = (try? c.decode([AIMode].self, forKey: .modes)) ?? AIMode.defaults
        activeModeID = (try? c.decode(UUID.self, forKey: .activeModeID)) ?? modes.first?.id
    }

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

    // MARK: Active Mode

    public var activeMode: AIMode? {
        guard let id = activeModeID else { return modes.first }
        return modes.first { $0.id == id } ?? modes.first
    }

    // MARK: Endpoint Lookup

    public func endpoint(for id: UUID?) -> APIEndpoint? {
        guard let id else { return nil }
        return endpoints.first { $0.id == id && $0.isEnabled }
    }
}
