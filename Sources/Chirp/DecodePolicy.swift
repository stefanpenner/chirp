// DecodePolicy.swift — Pure constants + guards for Transcriber decode window.
// Mirrors specs/TranscriberBuffer.tla: VAD endpoints; pendingAudio is decoded.
// Single source of truth for min lengths and speech-window rolls.

import Foundation

enum DecodePolicy {
    /// Sample rate used throughout the offline pipeline.
    static let sampleRate = 16_000

    /// Minimum pending samples before a VAD commit/flush may decode (~0.1s).
    static let minCommitSamples = 1_600

    /// Minimum pending samples before peek will run (~0.3s).
    static let peekMinSamples = 4_800

    /// Max seconds of pending audio used for peek (bounds latency).
    static let peekMaxSeconds = 5

    static var peekMaxSamples: Int { sampleRate * peekMaxSeconds }

    /// Pre-roll kept before first energy frame (~200ms).
    static let preRollSamples = 3_200

    /// Post-roll kept after last energy frame (~200ms).
    static let postRollSamples = 3_200

    /// Energy frame size for speech-window detection (~20ms).
    static let energyFrameSamples = 320

    /// RMS threshold for "speech-like" energy.
    static let energyThreshold: Float = 0.01

    /// Real-time chunk size used by audio capture / tests (~85ms).
    static let streamChunkSamples = 1_360

    /// VAD is endpoint-only; decode source is always the pending raw buffer.
    static let commitSourceIsPending = true

    /// Whether a buffer is long enough to commit/flush.
    static func canCommit(pendingSampleCount: Int) -> Bool {
        pendingSampleCount >= minCommitSamples
    }

    /// Whether a buffer is long enough to peek.
    static func canPeek(pendingSampleCount: Int, speechDetected: Bool) -> Bool {
        speechDetected && pendingSampleCount >= peekMinSamples
    }

    /// Cap peek window to the last peekMaxSeconds.
    static func peekWindowCount(pendingSampleCount: Int) -> Int {
        min(pendingSampleCount, peekMaxSamples)
    }

    // MARK: - Speculative preview cadence (SOTA: low time-to-first-partial)

    /// Peek interval while speech is active (~250ms).
    static let peekIntervalActiveNs: UInt64 = 250_000_000

    /// Peek interval after consecutive idle (no-speech) peeks — save CPU.
    static let peekIntervalIdleNs: UInt64 = 500_000_000

    /// Idle peeks before switching to the slower interval.
    static let peekIdleThreshold = 2

    /// Next sleep duration given consecutive idle miss count.
    static func peekSleepNs(idleMisses: Int) -> UInt64 {
        idleMisses >= peekIdleThreshold ? peekIntervalIdleNs : peekIntervalActiveNs
    }
}
