// DecodePolicy.swift — Pure constants + guards for Transcriber decode window.
// Mirrors specs/TranscriberBuffer.tla: VAD endpoints; pendingAudio is decoded.
// Single source of truth for min lengths and speech-window rolls.

import Foundation

enum DecodePolicy {
    /// Sample rate used throughout the offline pipeline.
    static let sampleRate = 16_000

    // MARK: - Silero VAD (sherpa-onnx) endpointing

    /// Speech probability threshold (higher → fewer false speech starts).
    static let vadThreshold: Float = 0.45

    /// Silence (seconds) after speech before a VAD endpoint.
    /// 0.55 matches LiveKit Silero defaults — slightly longer than 0.5s reduces
    /// mid-clause false endpoints during natural pauses (dictation SOTA).
    static let vadMinSilenceDuration: Float = 0.55

    /// Minimum speech (seconds) to count as a segment (filters clicks/noise).
    static let vadMinSpeechDuration: Float = 0.1

    /// Hard cap on continuous speech before forced endpoint (~15s).
    static let vadMaxSpeechDuration: Float = 15.0

    /// Silero window size in samples.
    static let vadWindowSize: Int = 512

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
    /// 0.005 (was 0.01): quiet talk without VP AGC often sits ~0.01–0.03 peak.
    static let energyThreshold: Float = 0.005

    /// Alias for adaptive floor lower bound (same value as energyThreshold).
    static let energyMinFloor: Float = energyThreshold

    /// Percentile of frame RMS used as the noise-floor estimate (20th).
    static let energyNoisePercentile: Float = 0.2

    /// Adaptive threshold = max(minFloor, noiseFloor * multiplier).
    /// Raises the gate above room noise so DecodeReject silence rejection
    /// is not weakened by noisy rooms counting as speech frames.
    /// 2.0 (was 2.5): less harsh on soft continuous speech.
    static let energyFloorMultiplier: Float = 2.0

    /// Cap adaptive thr at this fraction of peak frame RMS so soft, fairly
    /// uniform speech is not wiped (noiseFloor≈speech → thr > speech).
    static let energyPeakCapFraction: Float = 0.55

    /// Minimum frame count before adaptive floor estimation is trusted.
    static let energyFloorMinFrames = 2

    // MARK: - Soft input gain (quiet talk / far mic)

    /// Peaks below this are treated as silence (no boost).
    static let softGainMinPeak: Float = 0.004
    /// Peaks at or above this are already loud enough (no boost).
    static let softGainLoudGate: Float = 0.12
    /// Target peak after soft gain.
    static let softGainTargetPeak: Float = 0.28
    /// Cap amplification so silence/noise is not exploded.
    static let softGainMax: Float = 10

    /// Min peak/RMS (crest) before soft gain — rejects flat DC/room hiss.
    static let softGainMinCrest: Float = 1.8

    /// Boost soft (but non-silent) captures so VAD/energy/ASR see usable levels.
    /// Loud speech, near-silence, and flat noise are left unchanged.
    static func softInputGain(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        var sumSq: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += s * s
        }
        guard peak >= softGainMinPeak, peak < softGainLoudGate else {
            return samples
        }
        let rms = sqrtf(sumSq / Float(samples.count))
        let crest = peak / max(rms, 1e-6)
        // Flat hiss/DC has crest ≈ 1; speech envelopes are higher.
        guard crest >= softGainMinCrest else { return samples }
        let g = min(softGainMax, softGainTargetPeak / peak)
        guard g > 1.01 else { return samples }
        return samples.map { $0 * g }
    }

    /// Estimate noise floor from frame RMS values (energyNoisePercentile).
    static func noiseFloor(frameRMS: [Float]) -> Float {
        guard !frameRMS.isEmpty else { return 0 }
        let sorted = frameRMS.sorted()
        let idx = Int(Float(sorted.count - 1) * energyNoisePercentile)
        return sorted[max(0, min(idx, sorted.count - 1))]
    }

    /// Adaptive energy threshold: max(minFloor, noiseFloor * multiplier),
    /// capped vs peak so soft continuous speech still has speech frames.
    /// Falls back to fixed energyThreshold when too few frames to estimate.
    static func adaptiveEnergyThreshold(
        frameRMS: [Float],
        minFloor: Float = energyMinFloor,
        multiplier: Float = energyFloorMultiplier,
        peakCapFraction: Float = energyPeakCapFraction
    ) -> Float {
        guard frameRMS.count >= energyFloorMinFrames else {
            return energyThreshold
        }
        let floor = noiseFloor(frameRMS: frameRMS)
        var thr = max(minFloor, floor * multiplier)
        let peak = frameRMS.max() ?? 0
        // Soft speech with limited headroom over floor: uncapped thr (floor*mult)
        // can sit above every frame. Cap only when peak rises above the floor
        // (dynamic speech), not for flat noise (peak ≈ floor).
        if peak > floor * 1.5, peakCapFraction > 0, peakCapFraction < 1 {
            thr = min(thr, peak * peakCapFraction)
        }
        return max(minFloor, thr)
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

    /// Flush-only: re-decode empty / rejected but user already saw a non-empty peek.
    ///
    /// Closes empty-total vs live-peek gap at recording end (mid-session empty
    /// VAD commits still keep `pendingAudio` — not this path).
    ///
    /// Promote when:
    /// 1. Flush decode text is empty
    /// 2. VAD still had pending speech (same gate as flush body)
    /// 3. Pending long enough to commit
    /// 4. Last peek hyp non-empty (already passed DecodeReject at peek time)
    ///
    /// Dual: `PeekCommitHyp` PromoteEmpty.
    static func shouldPromotePeekOnEmptyFlush(
        flushText: String,
        lastPeekText: String?,
        hasPendingSpeech: Bool,
        pendingSampleCount: Int
    ) -> Bool {
        let trimmed = flushText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return false }
        guard hasPendingSpeech else { return false }
        guard canCommit(pendingSampleCount: pendingSampleCount) else { return false }
        guard let peek = lastPeekText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !peek.isEmpty
        else { return false }
        return true
    }
}
