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
}

extension AudioRecording {
    func prepare() {}
    func requestMicrophoneAccess() async -> Bool { true }
    func selectInputDevice(_ deviceID: AudioDeviceID?) {}
    var voiceProcessingEnabled: Bool {
        get { false }
        set {}
    }
}

/// Cursor move direction for word-level navigation (option+arrow).
enum MoveDirection: Equatable, Sendable {
    case left
    case right
}

/// Rich-text format styles applied via ⌘B / ⌘I / ⌘U on the current selection.
enum TextFormatStyle: Equatable, Sendable {
    case bold
    case italic
    case underline
}

@MainActor protocol TextInserting {
    func checkAccessibilityPermission()
    func typeText(_ text: String)
    func deleteBackward(count: Int)
    /// Select `count` characters backward (shift+left). Spoken "select that".
    func selectBackward(count: Int)
    /// Select all in the focused app (⌘A). Spoken "select all".
    func selectAll()
    /// Move cursor one word (option+left/right). Spoken "move left" / "move right".
    func moveWord(direction: MoveDirection)
    /// Move cursor to line start (⌘+left). Spoken "go to start".
    func moveToLineStart()
    /// Move cursor to line end (⌘+right). Spoken "go to end".
    func moveToLineEnd()
    /// Move cursor left `count` times (plain left arrow, no modifiers).
    func moveBackward(count: Int)
    /// Move cursor right `count` times (plain right arrow, no modifiers).
    func moveForward(count: Int)
    /// Apply rich-text format to the current selection (⌘B / ⌘I / ⌘U).
    func applyFormat(_ style: TextFormatStyle)
    /// Collapse selection to its end (right-arrow without shift). Spoken "unselect that".
    func clearSelection()
    /// Cut the current selection to the clipboard (⌘X). Spoken "cut that".
    func cutSelection()
    /// Copy `text` to the system pasteboard (spoken "copy that").
    func copyToClipboard(_ text: String)
    /// Paste from the system pasteboard into the focused app (spoken "paste that").
    func pasteFromClipboard()
    /// Current pasteboard string, if any.
    func clipboardString() -> String?
}

extension TextInserting {
    func selectBackward(count: Int) {}
    func selectAll() {}
    func moveWord(direction: MoveDirection) {}
    func moveToLineStart() {}
    func moveToLineEnd() {}
    func moveBackward(count: Int) {}
    func moveForward(count: Int) {}
    func applyFormat(_ style: TextFormatStyle) {}
    func clearSelection() {}
    func cutSelection() {}
    func copyToClipboard(_ text: String) {}
    func pasteFromClipboard() {}
    func clipboardString() -> String? { nil }
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
