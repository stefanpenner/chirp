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

    /// Fixed / minimum RMS threshold for "speech-like" energy.
    /// Also used when too few frames exist to estimate a noise floor.
    static let energyThreshold: Float = 0.01

    /// Alias for adaptive floor lower bound (same value as energyThreshold).
    static let energyMinFloor: Float = energyThreshold

    /// Percentile of frame RMS used as the noise-floor estimate (20th).
    static let energyNoisePercentile: Float = 0.2

    /// Adaptive threshold = max(minFloor, noiseFloor * multiplier).
    /// Raises the gate above room noise so DecodeReject silence rejection
    /// is not weakened by noisy rooms counting as speech frames.
    static let energyFloorMultiplier: Float = 2.5

    /// Minimum frame count before adaptive floor estimation is trusted.
    static let energyFloorMinFrames = 2

    /// Estimate noise floor from frame RMS values (energyNoisePercentile).
    static func noiseFloor(frameRMS: [Float]) -> Float {
        guard !frameRMS.isEmpty else { return 0 }
        let sorted = frameRMS.sorted()
        let idx = Int(Float(sorted.count - 1) * energyNoisePercentile)
        return sorted[max(0, min(idx, sorted.count - 1))]
    }

    /// Adaptive energy threshold: max(minFloor, noiseFloor * multiplier).
    /// Falls back to fixed energyThreshold when too few frames to estimate.
    static func adaptiveEnergyThreshold(
        frameRMS: [Float],
        minFloor: Float = energyMinFloor,
        multiplier: Float = energyFloorMultiplier
    ) -> Float {
        guard frameRMS.count >= energyFloorMinFrames else {
            return energyThreshold
        }
        return max(minFloor, noiseFloor(frameRMS: frameRMS) * multiplier)
    }

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

    // MARK: - Peek decode cache (skip ASR when pending length unchanged)

    /// Whether a prior peek decode can be reused for the current pending count.
    /// True when we have a cached count and it equals `currentCount`.
    /// Dual: `specs/PeekCache.tla`. Empty prior text still reuses (skip silence ASR).
    static func shouldReusePeek(lastCount: Int?, currentCount: Int) -> Bool {
        lastCount != nil && lastCount == currentCount
    }

    // MARK: - Peek → commit hyp reuse (speech-window match)

    /// Cheap fingerprint of a speech-window sample buffer.
    /// Count + first/last edge samples so trailing silence on pendingAudio
    /// (same speech content) still matches while new speech does not.
    struct SpeechWindowSignature: Equatable, Sendable {
        let sampleCount: Int
        let edgeHash: UInt64
    }

    /// Fingerprint `samples` for commit-hyp reuse comparison.
    static func speechWindowSignature(_ samples: [Float]) -> SpeechWindowSignature {
        var h: UInt64 = 1_469_598_103_934_665_603_7 // FNV offset basis
        let n = samples.count
        guard n > 0 else { return SpeechWindowSignature(sampleCount: 0, edgeHash: 0) }
        let edge = min(8, n)
        for i in 0..<edge {
            h ^= UInt64(samples[i].bitPattern)
            h &*= 1_099_511_628_211
        }
        for i in (n - edge)..<n {
            h ^= UInt64(samples[i].bitPattern)
            h &*= 1_099_511_628_211
        }
        h ^= UInt64(n)
        return SpeechWindowSignature(sampleCount: n, edgeHash: h)
    }

    /// Whether a prior peek hyp can satisfy commit/flush without re-decode.
    ///
    /// Safe when:
    /// 1. Cached hyp is non-empty
    /// 2. Pending buffer fits entirely in the peek window (≤ peekMaxSamples)
    ///    so peek did not drop a leading prefix of the utterance
    /// 3. Speech-window signature matches (trailing silence may grow pending
    ///    count but energy trim yields the same speech content)
    ///
    /// Dual: `specs/PeekCommitHyp.tla`.
    static func shouldReuseCommitHyp(
        cachedSignature: SpeechWindowSignature?,
        cachedText: String?,
        windowSamples: [Float],
        pendingSampleCount: Int
    ) -> Bool {
        guard let cachedSignature, let text = cachedText, !text.isEmpty else { return false }
        guard pendingSampleCount <= peekMaxSamples else { return false }
        return speechWindowSignature(windowSamples) == cachedSignature
    }
}
