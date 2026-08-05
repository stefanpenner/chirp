// AppStatusDecision.swift — Pure gates for AppState.Status boot + session entry.
// Mirrors specs/AppStatus.tla. Session rejoin/gen stays in SessionDecision /
// SessionMachine.tla; this covers stuck-mode UI (download/load/error/ready).

import Foundation

/// Status kind without progress/message payloads (TLA dual of AppStatus.status).
enum AppStatusKind: String, Sendable, Equatable {
    case needsModel
    case downloading
    case loadingModel
    case ready
    case recording
    case transcribing
    case error
}

/// Pure decision gates for boot + session entry (no I/O).
enum AppStatusDecision {
    /// Map full AppState.Status → kind (strip progress / error string).
    static func kind(from status: AppState.Status) -> AppStatusKind {
        switch status {
        case .needsModel: return .needsModel
        case .downloading: return .downloading
        case .loadingModel: return .loadingModel
        case .ready: return .ready
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .error: return .error
        }
    }

    /// StartDownload / retryDownload: needsModel | error (and load-path re-entry).
    /// Dual of AppStatus StartDownload from needsModel | error.
    static func canRetryDownload(_ kind: AppStatusKind) -> Bool {
        kind == .needsModel || kind == .error
    }

    /// CancelDownload only while downloading.
    static func canCancelDownload(_ kind: AppStatusKind) -> Bool {
        kind == .downloading
    }

    /// Hotkey during download/load → nudge, do not start session.
    static func shouldNudgeInsteadOfRecord(_ kind: AppStatusKind) -> Bool {
        kind == .downloading || kind == .loadingModel
    }

    /// Hotkey with no model → kick ensureModel / download.
    static func shouldStartDownloadOnHotkey(_ kind: AppStatusKind) -> Bool {
        kind == .needsModel
    }

    /// ready → recording only.
    static func canEnterSession(_ kind: AppStatusKind) -> Bool {
        kind == .ready
    }

    /// transcribing → recording rejoin (coarse; SessionDecision for phase).
    static func canRejoinSession(_ kind: AppStatusKind) -> Bool {
        kind == .transcribing
    }

    /// Island should stay ordered front for download, session, or post-fail error.
    /// Dual of OverlayWhileDownloading / OverlayWhileSession (+ error keep).
    static func shouldShowOverlay(_ kind: AppStatusKind) -> Bool {
        switch kind {
        case .downloading, .recording, .transcribing, .error:
            return true
        case .loadingModel, .ready, .needsModel:
            return false
        }
    }

    /// Short menu/overlay label for non-session statuses.
    static func statusLabel(_ kind: AppStatusKind) -> String? {
        switch kind {
        case .needsModel: return "Speech model required"
        case .downloading: return "Downloading model\u{2026}"
        case .loadingModel: return "Loading model\u{2026}"
        case .error: return "Something went wrong"
        case .ready, .recording, .transcribing: return nil
        }
    }
}
