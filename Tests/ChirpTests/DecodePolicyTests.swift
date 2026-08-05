// DecodePolicyTests.swift — Pure policy dual-tested against TranscriberBuffer.tla.

import Testing
@testable import Chirp

@Suite("DecodePolicy")
struct DecodePolicyTests {

    @Test("commit source is always pending")
    func commitSourcePending() {
        #expect(DecodePolicy.commitSourceIsPending)
    }

    @Test("Silero VAD endpoint constants are dictation-tuned")
    func vadEndpointConstants() {
        #expect(DecodePolicy.vadThreshold > 0 && DecodePolicy.vadThreshold < 1)
        // Prefer ≥0.5s silence so natural mid-clause pauses do not false-endpoint
        #expect(DecodePolicy.vadMinSilenceDuration >= 0.5)
        #expect(DecodePolicy.vadMinSilenceDuration <= 1.0)
        #expect(DecodePolicy.vadMinSpeechDuration > 0)
        #expect(DecodePolicy.vadMaxSpeechDuration >= 10)
        #expect(DecodePolicy.vadWindowSize == 512)
    }

    @Test("canCommit threshold")
    func canCommit() {
        #expect(!DecodePolicy.canCommit(pendingSampleCount: 0))
        #expect(!DecodePolicy.canCommit(pendingSampleCount: DecodePolicy.minCommitSamples - 1))
        #expect(DecodePolicy.canCommit(pendingSampleCount: DecodePolicy.minCommitSamples))
        #expect(DecodePolicy.canCommit(pendingSampleCount: 16_000))
    }

    @Test("canPeek requires speech and min samples")
    func canPeek() {
        #expect(!DecodePolicy.canPeek(pendingSampleCount: 10_000, speechDetected: false))
        #expect(!DecodePolicy.canPeek(pendingSampleCount: 100, speechDetected: true))
        #expect(DecodePolicy.canPeek(
            pendingSampleCount: DecodePolicy.peekMinSamples,
            speechDetected: true
        ))
    }

    @Test("peek window caps at max")
    func peekWindow() {
        #expect(DecodePolicy.peekWindowCount(pendingSampleCount: 100) == 100)
        #expect(
            DecodePolicy.peekWindowCount(pendingSampleCount: DecodePolicy.peekMaxSamples + 999)
                == DecodePolicy.peekMaxSamples
        )
    }

    @Test("adaptive peek sleep: active then idle")
    func adaptivePeekSleep() {
        #expect(DecodePolicy.peekSleepNs(idleMisses: 0) == DecodePolicy.peekIntervalActiveNs)
        #expect(DecodePolicy.peekSleepNs(idleMisses: 1) == DecodePolicy.peekIntervalActiveNs)
        #expect(DecodePolicy.peekSleepNs(idleMisses: 2) == DecodePolicy.peekIntervalIdleNs)
        #expect(DecodePolicy.peekSleepNs(idleMisses: 5) == DecodePolicy.peekIntervalIdleNs)
        #expect(DecodePolicy.peekIntervalActiveNs < DecodePolicy.peekIntervalIdleNs)
    }

    // MARK: - Peek cache reuse (PeekCache.tla)

    @Test("shouldReusePeek: first peek has no cache")
    func shouldReusePeekFirst() {
        #expect(!DecodePolicy.shouldReusePeek(lastCount: nil, currentCount: 4800))
        #expect(!DecodePolicy.shouldReusePeek(lastCount: nil, currentCount: 0))
    }

    @Test("shouldReusePeek: same count reuses")
    func shouldReusePeekSameCount() {
        #expect(DecodePolicy.shouldReusePeek(lastCount: 4800, currentCount: 4800))
        #expect(DecodePolicy.shouldReusePeek(lastCount: 16_000, currentCount: 16_000))
        #expect(DecodePolicy.shouldReusePeek(lastCount: 0, currentCount: 0))
    }

    @Test("shouldReusePeek: count change does not reuse")
    func shouldReusePeekCountChanged() {
        #expect(!DecodePolicy.shouldReusePeek(lastCount: 4800, currentCount: 4801))
        #expect(!DecodePolicy.shouldReusePeek(lastCount: 4800, currentCount: 4799))
        #expect(!DecodePolicy.shouldReusePeek(lastCount: 100, currentCount: 0))
    }

    // MARK: - Peek → commit hyp reuse (PeekCommitHyp.tla)

    @Test("speechWindowSignature is stable for identical samples")
    func speechWindowSignatureStable() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.0, 0.0]
        let a = DecodePolicy.speechWindowSignature(samples)
        let b = DecodePolicy.speechWindowSignature(samples)
        #expect(a == b)
        #expect(a.sampleCount == samples.count)
    }

    @Test("speechWindowSignature changes when content changes")
    func speechWindowSignatureSensitive() {
        let a = DecodePolicy.speechWindowSignature([0.1, 0.2, 0.3])
        let b = DecodePolicy.speechWindowSignature([0.1, 0.2, 0.4])
        let c = DecodePolicy.speechWindowSignature([0.1, 0.2, 0.3, 0.0])
        #expect(a != b)
        #expect(a != c)
    }

    @Test("shouldReuseCommitHyp: matching window and hyp within peek max")
    func shouldReuseCommitHypHappyPath() {
        let window: [Float] = [0.1, 0.2, 0.3, 0.4]
        let sig = DecodePolicy.speechWindowSignature(window)
        #expect(DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: "hello",
            windowSamples: window,
            pendingSampleCount: window.count
        ))
        // Trailing silence grows pending but speech window is the same
        #expect(DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: "hello",
            windowSamples: window,
            pendingSampleCount: window.count + 8_000
        ))
    }

    @Test("shouldReuseCommitHyp: rejects empty hyp, sig miss, over peek max")
    func shouldReuseCommitHypRejects() {
        let window: [Float] = [0.1, 0.2, 0.3]
        let sig = DecodePolicy.speechWindowSignature(window)
        #expect(!DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: nil,
            cachedText: "hello",
            windowSamples: window,
            pendingSampleCount: 100
        ))
        #expect(!DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: nil,
            windowSamples: window,
            pendingSampleCount: 100
        ))
        #expect(!DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: "",
            windowSamples: window,
            pendingSampleCount: 100
        ))
        #expect(!DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: "hello",
            windowSamples: [0.9, 0.8, 0.7],
            pendingSampleCount: 100
        ))
        #expect(!DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: sig,
            cachedText: "hello",
            windowSamples: window,
            pendingSampleCount: DecodePolicy.peekMaxSamples + 1
        ))
    }

    @Test("shouldPromotePeekOnEmptyFlush: empty total + live peek + speech")
    func promotePeekOnEmptyFlush() {
        #expect(DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "",
            lastPeekText: "hello world",
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples
        ))
        #expect(DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "   ",
            lastPeekText: "yes please",
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples + 100
        ))
    }

    @Test("shouldPromotePeekOnEmptyFlush: rejects when unsafe")
    func promotePeekRejects() {
        // Non-empty flush already won
        #expect(!DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "kept",
            lastPeekText: "hello",
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples
        ))
        // No VAD speech — flush skip path (hallucination guard)
        #expect(!DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "",
            lastPeekText: "hello",
            hasPendingSpeech: false,
            pendingSampleCount: DecodePolicy.minCommitSamples
        ))
        // Too short pending
        #expect(!DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "",
            lastPeekText: "hello",
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples - 1
        ))
        // No peek
        #expect(!DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "",
            lastPeekText: nil,
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples
        ))
        #expect(!DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: "",
            lastPeekText: "  ",
            hasPendingSpeech: true,
            pendingSampleCount: DecodePolicy.minCommitSamples
        ))
    }

    // MARK: - Adaptive energy noise floor

    @Test("noiseFloor tracks low RMS values (≈20th percentile)")
    func noiseFloorLowValues() {
        let rms: [Float] = [0.01, 0.01, 0.5, 0.6]
        let floor = DecodePolicy.noiseFloor(frameRMS: rms)
        #expect(floor <= 0.01 + 1e-6)
        #expect(floor >= 0)
    }

    @Test("noiseFloor empty returns zero")
    func noiseFloorEmpty() {
        #expect(DecodePolicy.noiseFloor(frameRMS: []) == 0)
    }

    @Test("adaptiveEnergyThreshold is at least minFloor")
    func adaptiveThresholdMinFloor() {
        let quiet: [Float] = [0.001, 0.002, 0.001, 0.003]
        let t = DecodePolicy.adaptiveEnergyThreshold(frameRMS: quiet)
        #expect(t >= DecodePolicy.energyThreshold)
        #expect(t >= DecodePolicy.energyMinFloor)
    }

    @Test("adaptiveEnergyThreshold rises above room noise")
    func adaptiveThresholdAboveNoise() {
        // Quiet room ~0.02; speech-like frames higher.
        let rms: [Float] = [
            0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02,
            0.4, 0.5, 0.45, 0.02, 0.02, 0.02, 0.02, 0.02,
        ]
        let t = DecodePolicy.adaptiveEnergyThreshold(frameRMS: rms)
        #expect(t > 0.02)
        #expect(t < 0.4)
        // noiseFloor * multiplier ≈ 0.02 * 2.0 (capped by peak if needed)
        let expected = 0.02 * DecodePolicy.energyFloorMultiplier
        #expect(abs(t - expected) < 0.02 || t <= 0.5 * DecodePolicy.energyPeakCapFraction + 0.01)
    }

    @Test("adaptiveEnergyThreshold falls back to fixed when too few frames")
    func adaptiveThresholdFewFrames() {
        #expect(
            DecodePolicy.adaptiveEnergyThreshold(frameRMS: [])
                == DecodePolicy.energyThreshold
        )
        #expect(
            DecodePolicy.adaptiveEnergyThreshold(frameRMS: [0.5])
                == DecodePolicy.energyThreshold
        )
    }

    @Test("adaptiveEnergyThreshold peak-caps soft speech with dynamic range")
    func adaptiveThresholdSoftSpeechPeakCap() {
        // Quiet floor + soft peaks (speech envelope), not flat noise.
        var soft: [Float] = []
        for i in 0..<40 {
            soft.append(i % 4 == 0 ? 0.06 : 0.015)
        }
        let t = DecodePolicy.adaptiveEnergyThreshold(frameRMS: soft)
        #expect(t < 0.06)
        #expect(soft.filter { $0 >= t }.count >= 8)
    }

    @Test("softInputGain boosts quiet speech-like envelope")
    func softInputGainBoostsQuiet() {
        // Alternating soft peaks (crest > 1.8) — not flat DC.
        var quiet: [Float] = []
        for i in 0..<200 {
            quiet.append(i % 5 == 0 ? 0.04 : 0.008)
        }
        let boosted = DecodePolicy.softInputGain(quiet)
        let peak = boosted.map { abs($0) }.max() ?? 0
        #expect(peak > 0.1)
        #expect(peak <= DecodePolicy.softGainTargetPeak + 0.02)
    }

    @Test("softInputGain leaves loud, flat noise, and near-silence alone")
    func softInputGainPassthrough() {
        let loud = [Float](repeating: 0.4, count: 50)
        #expect(DecodePolicy.softInputGain(loud) == loud)
        let silence = [Float](repeating: 0.0005, count: 50)
        #expect(DecodePolicy.softInputGain(silence) == silence)
        let flatNoise = [Float](repeating: 0.02, count: 100)
        #expect(DecodePolicy.softInputGain(flatNoise) == flatNoise)
    }

    @Test("energy floor constants are dual-testable")
    func energyFloorConstants() {
        #expect(DecodePolicy.energyMinFloor == DecodePolicy.energyThreshold)
        #expect(DecodePolicy.energyFloorMultiplier == 2.0)
        #expect(DecodePolicy.energyPeakCapFraction > 0 && DecodePolicy.energyPeakCapFraction < 1)
        #expect(DecodePolicy.energyNoisePercentile > 0 && DecodePolicy.energyNoisePercentile < 0.5)
        #expect(DecodePolicy.energyFloorMinFrames >= 2)
        #expect(DecodePolicy.softGainMax >= 4)
        #expect(DecodePolicy.softGainMinPeak < DecodePolicy.softGainLoudGate)
    }
}
