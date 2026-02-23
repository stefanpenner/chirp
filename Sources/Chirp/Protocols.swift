// Protocols.swift — Dependency injection boundaries.
// AppState depends on these protocols rather than concrete types,
// enabling mock-based testing without audio hardware or ML models.

import CoreAudio
import Foundation

struct ModelPaths: Sendable {
    let modelDir: String
    let vadPath: String
}

protocol TranscriberProtocol: Sendable {
    func initialize(paths: ModelPaths) async -> Bool
    func feedAudio(samples: [Float]) async -> [String]
    func peekTranscription() async -> String?
    func flush() async -> String
    func resetVAD() async
}

@MainActor protocol AudioRecording {
    func requestMicrophoneAccess() async -> Bool
    func prepare()
    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void)
    func stopRecording()
    func selectInputDevice(_ deviceID: AudioDeviceID?)
    var voiceProcessingEnabled: Bool { get set }
    var silenceGateThreshold: Float { get set }
}

extension AudioRecording {
    func prepare() {}
    func requestMicrophoneAccess() async -> Bool { true }
    func selectInputDevice(_ deviceID: AudioDeviceID?) {}
    var voiceProcessingEnabled: Bool {
        get { false }
        set {}
    }
    var silenceGateThreshold: Float {
        get { 0 }
        set {}
    }
}

@MainActor protocol TextInserting {
    func checkAccessibilityPermission()
    func typeText(_ text: String)
    func deleteBackward(count: Int)
}

protocol SpeakerVerifying: Sendable {
    func loadModel(path: String) async throws
    func extractEmbedding(samples: [Float]) async throws -> [Float]
    func verify(samples: [Float]) async throws -> Float
    func isMatch(samples: [Float], threshold: Float) async throws -> Bool
    func enroll(embeddings: [[Float]]) async
    func setReferenceEmbedding(_ embedding: [Float]?) async
    var hasReference: Bool { get async }
}
