import Foundation
@testable import Chirp

actor MockTranscriber: TranscriberProtocol {
    var initializeResult = false
    var feedAudioResult: [String] = []
    var peekResult: String? = nil
    var flushResult: String = ""

    var initializeCalled = false
    var feedAudioCallCount = 0
    var peekCalled = false
    var flushCalled = false
    var resetVADCalled = false

    func initialize(paths: ModelPaths) -> Bool {
        initializeCalled = true
        return initializeResult
    }

    func feedAudio(samples: [Float]) -> [String] {
        feedAudioCallCount += 1
        return feedAudioResult
    }

    func peekTranscription() -> String? {
        peekCalled = true
        return peekResult
    }

    func flush() -> String {
        flushCalled = true
        return flushResult
    }

    func resetVAD() {
        resetVADCalled = true
    }
}

@MainActor
final class MockAudioRecorder: AudioRecording {
    var isRecording = false
    var lastOnSamples: (([Float]) -> Void)?

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        isRecording = true
        lastOnSamples = onSamples
    }

    func stopRecording() {
        isRecording = false
        lastOnSamples = nil
    }
}

@MainActor
final class MockTextInserter: TextInserting {
    var accessibilityChecked = false
    var typedTexts: [String] = []
    var deletedCounts: [Int] = []

    func checkAccessibilityPermission() {
        accessibilityChecked = true
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        typedTexts.append(text)
    }

    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        deletedCounts.append(count)
    }
}
