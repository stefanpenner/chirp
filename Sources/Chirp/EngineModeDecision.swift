// EngineModeDecision.swift — Pure resolve/fallback for STT engine selection.
// Dual of specs/EngineMode.tla: optional engines fall back to offline;
// mid-session desired changes defer (see PipelineRebuildDecision).

import Foundation

/// Pure engine-mode gates (no I/O). Product default remains offline Parakeet.
enum EngineModeDecision {
    /// Resolve user-desired transcription mode against runtime availability.
    /// - offline / cloud: always resolved as-is (cloud errors surface later).
    /// - systemSpeech: requires Apple SpeechAnalyzer path (macOS 26+).
    /// Unavailable optional engines → offline (never stick on a dead engine).
    ///
    /// `fluidAvailable` is reserved for a future FluidAudio ANE mode (TLA "fluid");
    /// product has no enum case yet — always treat as unavailable.
    static func resolve(
        desired: TranscriptionMode,
        systemAvailable: Bool,
        fluidAvailable: Bool = false
    ) -> TranscriptionMode {
        // fluidAvailable reserved for EngineMode.tla dual; no product case yet.
        _ = fluidAvailable
        switch desired {
        case .offline:
            return .offline
        case .cloud:
            return .cloud
        case .systemSpeech:
            return systemAvailable ? .systemSpeech : .offline
        }
    }

    /// Mid-session desired/availability change must not rebuild the live pipeline.
    /// Dual of EngineMode SelectActive / PipelineRebuild.shouldDefer.
    static func shouldDeferApply(sessionActive: Bool) -> Bool {
        sessionActive
    }

    /// Idle + pending rebuild may apply resolved mode.
    static func canApplyResolved(sessionActive: Bool, needsRebuild: Bool) -> Bool {
        needsRebuild && !sessionActive
    }

    /// Active engine must be legal under current availability (observational dual).
    static func isLegalActive(
        _ active: TranscriptionMode,
        systemAvailable: Bool,
        fluidAvailable: Bool = false
    ) -> Bool {
        _ = fluidAvailable
        switch active {
        case .offline, .cloud:
            return true
        case .systemSpeech:
            return systemAvailable
        }
    }
}
