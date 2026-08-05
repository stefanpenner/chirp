// StreamingPartialDecision.swift — Pure gates for peek-only vs streaming EOU.
// Dual of specs/StreamingPartial.tla. Product ships peekOnly only; streamingEOU
// is modeled for future trial (FluidAudio EOU / true partials) without enabling it.

import Foundation

/// How live text is produced during a recording session.
enum PartialEngineMode: String, Sendable, Equatable {
    /// Shipped: offline re-decode of pendingAudio on AdaptivePeek cadence.
    case peekOnly
    /// Deferred: true streaming ASR + end-of-utterance auto-commit.
    case streamingEOU
}

/// Session phase subset for partial/EOU gates (dual of StreamingPartial.phase).
enum PartialSessionPhase: String, Sendable, Equatable {
    case ready
    case recording
    case transcribing
}

/// Pure policy for speculative partials and EOU commit (no I/O).
enum StreamingPartialDecision {
    /// Product default — must stay peek-only until a streaming engine ships.
    static let productDefault: PartialEngineMode = .peekOnly

    /// Whether speculative / streaming partial UI may be non-empty.
    /// Dual: PartialOnlyInSession.
    static func canShowPartial(phase: PartialSessionPhase) -> Bool {
        phase == .recording || phase == .transcribing
    }

    /// EOU signal is only meaningful in streaming mode.
    /// Dual: EOUOnlyStreaming / PeekOnlyNoEOU.
    static func acceptsEOU(mode: PartialEngineMode) -> Bool {
        mode == .streamingEOU
    }

    /// Auto-commit on EOU only when streaming + recording + had partial + eou fired.
    /// Peek-only never auto-commits via EOU (VAD commit / flush only).
    static func shouldAutoCommitOnEOU(
        mode: PartialEngineMode,
        phase: PartialSessionPhase,
        eouFired: Bool,
        partialNonEmpty: Bool
    ) -> Bool {
        mode == .streamingEOU
            && phase == .recording
            && eouFired
            && partialNonEmpty
    }

    /// Peek-only path may emit a speculative partial only while recording + speech.
    static func canPeekPartial(
        mode: PartialEngineMode,
        phase: PartialSessionPhase,
        speechActive: Bool
    ) -> Bool {
        mode == .peekOnly && phase == .recording && speechActive
    }

    /// Streaming path may emit a growing partial under the same speech gate.
    static func canStreamPartial(
        mode: PartialEngineMode,
        phase: PartialSessionPhase,
        speechActive: Bool
    ) -> Bool {
        mode == .streamingEOU && phase == .recording && speechActive
    }

    /// Map AppState.Status → partial phase when in a session lifecycle status.
    static func phase(from status: AppState.Status) -> PartialSessionPhase? {
        switch status {
        case .ready: return .ready
        case .recording: return .recording
        case .transcribing: return .transcribing
        default: return nil
        }
    }
}
