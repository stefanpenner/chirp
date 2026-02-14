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
    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void)
    func stopRecording()
}

@MainActor protocol TextInserting {
    func checkAccessibilityPermission()
    func typeText(_ text: String)
    func deleteBackward(count: Int)
}
