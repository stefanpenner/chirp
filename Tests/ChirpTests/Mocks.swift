import Foundation
@testable import Chirp

actor MockTranscriber: TranscriberProtocol {
    var initializeResult = false
    var feedAudioResult: [String] = []
    var peekResult: String? = nil
    var flushResult: String = ""
    var feedAudioDelay: UInt64 = 0  // nanoseconds
    var flushDelay: UInt64 = 0  // nanoseconds

    var initializeCalled = false
    var feedAudioCallCount = 0
    var peekCalled = false
    var flushCalled = false
    var resetVADCalled = false

    func initialize(paths: ModelPaths) -> Bool {
        initializeCalled = true
        return initializeResult
    }

    var feedAudioHandler: (@Sendable ([Float]) -> [String])? = nil

    func feedAudio(samples: [Float]) async -> [String] {
        feedAudioCallCount += 1
        if feedAudioDelay > 0 {
            try? await Task.sleep(nanoseconds: feedAudioDelay)
        }
        if let handler = feedAudioHandler { return handler(samples) }
        return feedAudioResult
    }

    func setInitializeResult(_ value: Bool) { initializeResult = value }
    func setFeedAudioResult(_ value: [String]) { feedAudioResult = value }
    func setFlushResult(_ value: String) { flushResult = value }
    func setFeedAudioDelay(_ value: UInt64) { feedAudioDelay = value }
    func setFlushDelay(_ value: UInt64) { flushDelay = value }
    func setPeekResult(_ value: String?) { peekResult = value }
    func setFeedAudioHandler(_ handler: @escaping @Sendable ([Float]) -> [String]) { feedAudioHandler = handler }

    func peekTranscription() -> String? {
        peekCalled = true
        return peekResult
    }

    func flush() async -> String {
        if flushDelay > 0 {
            try? await Task.sleep(nanoseconds: flushDelay)
        }
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
    var prepareCalled = false
    var microphoneAccessGranted = true
    var voiceProcessingEnabled: Bool = false
    var startCallCount = 0
    var stopCallCount = 0
    /// Tracks whether startRecording was called while already recording (double-start).
    var doubleStartDetected = false

    func requestMicrophoneAccess() async -> Bool {
        microphoneAccessGranted
    }

    func prepare() {
        prepareCalled = true
    }

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        if isRecording { doubleStartDetected = true }
        startCallCount += 1
        isRecording = true
        lastOnSamples = onSamples
    }

    func stopRecording() {
        stopCallCount += 1
        isRecording = false
        lastOnSamples = nil
    }
}

actor MockSpeakerVerifier: SpeakerVerifying {
    var verifyResult: Float = 1.0
    var extractResult: [Float] = Array(repeating: 0, count: 192)
    var loadCalled = false
    var enrollCalled = false
    var verifyCalled = false
    var _hasReference = false

    var hasReference: Bool { _hasReference }

    func loadModel(path: String) throws {
        loadCalled = true
    }

    func extractEmbedding(samples: [Float]) throws -> [Float] {
        extractResult
    }

    func verify(samples: [Float]) throws -> Float {
        verifyCalled = true
        return verifyResult
    }

    func isMatch(samples: [Float], threshold: Float) throws -> Bool {
        verifyCalled = true
        return verifyResult >= threshold
    }

    func enroll(embeddings: [[Float]]) {
        enrollCalled = true
        _hasReference = true
    }

    func setReferenceEmbedding(_ embedding: [Float]?) {
        _hasReference = embedding != nil
    }

    func setVerifyResult(_ value: Float) { verifyResult = value }
    func setHasReference(_ value: Bool) { _hasReference = value }
}

@MainActor
final class MockTextInserter: TextInserting {
    var accessibilityChecked = false
    var typedTexts: [String] = []
    var deletedCounts: [Int] = []
    var selectBackwardCounts: [Int] = []
    var selectAllCalled = false
    var moveWordDirections: [MoveDirection] = []
    var moveLineDirections: [MoveDirection] = []
    var moveToLineStartCalled = false
    var moveToLineEndCalled = false
    var moveBackwardCounts: [Int] = []
    var moveForwardCounts: [Int] = []
    var appliedFormats: [TextFormatStyle] = []
    var cutCallCount = 0
    var clearSelectionCallCount = 0
    var clipboard: String = ""
    var pasteCallCount = 0
    var copyCallCount = 0

    func checkAccessibilityPermission() {
        accessibilityChecked = true
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        typedTexts.append(text)
    }

    func copyToClipboard(_ text: String) {
        copyCallCount += 1
        clipboard = text
    }

    func pasteFromClipboard() {
        pasteCallCount += 1
        if !clipboard.isEmpty {
            typedTexts.append(clipboard)
        }
    }

    func clipboardString() -> String? {
        clipboard.isEmpty ? nil : clipboard
    }

    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        deletedCounts.append(count)
    }

    func selectBackward(count: Int) {
        guard count > 0 else { return }
        selectBackwardCounts.append(count)
    }

    func selectAll() {
        selectAllCalled = true
    }

    func moveWord(direction: MoveDirection) {
        moveWordDirections.append(direction)
    }

    func moveLine(direction: MoveDirection) {
        moveLineDirections.append(direction)
    }

    func moveToLineStart() {
        moveToLineStartCalled = true
    }

    func moveToLineEnd() {
        moveToLineEndCalled = true
    }

    func moveBackward(count: Int) {
        guard count > 0 else { return }
        moveBackwardCounts.append(count)
    }

    func moveForward(count: Int) {
        guard count > 0 else { return }
        moveForwardCounts.append(count)
    }

    func applyFormat(_ style: TextFormatStyle) {
        appliedFormats.append(style)
    }

    func clearSelection() {
        // Format collapse / unselect that — no buffer side effects in tests.
        clearSelectionCallCount += 1
    }

    func cutSelection() {
        cutCallCount += 1
    }
}

final class Counter: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

struct MockSTTClient: STTClient {
    let result: String
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        result
    }
}
