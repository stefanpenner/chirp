// Protocols.swift — Dependency injection boundaries.
// AppState depends on these protocols rather than concrete types,
// enabling mock-based testing without audio hardware or ML models.

import Foundation

struct ModelPaths: Sendable {
    let modelDir: String
    let vadPath: String
    let variant: ModelVariant
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
}

extension AudioRecording {
    func prepare() {}
    func requestMicrophoneAccess() async -> Bool { true }
}

@MainActor protocol TextInserting {
    func checkAccessibilityPermission()
    func typeText(_ text: String)
    func deleteBackward(count: Int)
}
