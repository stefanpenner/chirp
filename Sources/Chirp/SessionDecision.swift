// SessionDecision.swift — Pure decision gate for hold-to-talk session transitions.
// Mirrors specs/SessionMachine.tla (Can* guards). AppState mechanics call these
// so session policy stays centralized and dual-testable against the TLA+ model.

import Foundation

/// Session lifecycle status used by the pure decision gate.
/// Subset of AppState.Status focused on recording sessions.
enum SessionPhase: String, Sendable, Equatable {
    case ready
    case recording
    case transcribing
}

/// Pure functions for session transition guards (no I/O, no side effects).
enum SessionDecision {
    /// StartRecording: ready → recording
    static func canStartRecording(_ phase: SessionPhase) -> Bool {
        phase == .ready
    }

    /// StopRecording: recording → transcribing
    static func canStopRecording(_ phase: SessionPhase) -> Bool {
        phase == .recording
    }

    /// Rejoin: transcribing → recording (same session, keep text)
    static func canRejoin(_ phase: SessionPhase) -> Bool {
        phase == .transcribing
    }

    /// Cancel: recording | transcribing → ready
    static func canCancel(_ phase: SessionPhase) -> Bool {
        phase == .recording || phase == .transcribing
    }

    /// FinishSession: transcribing → ready (consumer done)
    static func canFinish(_ phase: SessionPhase) -> Bool {
        phase == .transcribing
    }

    /// Whether a consumer may apply commits / flush results.
    /// Dual of SessionMachine CommitText guard on active gen (yodel-adv4).
    /// Rejoin keeps `recordingSession` but bumps `consumerGeneration` so a
    /// cancelled cooperative task cannot double-apply after the new consumer starts.
    static func canApplyConsumerWork(taskGen: UInt64, activeGen: UInt64) -> Bool {
        taskGen == activeGen
    }

    /// Map AppState.Status into the session phase subset when applicable.
    static func phase(from status: AppState.Status) -> SessionPhase? {
        switch status {
        case .ready: return .ready
        case .recording: return .recording
        case .transcribing: return .transcribing
        default: return nil
        }
    }
}
