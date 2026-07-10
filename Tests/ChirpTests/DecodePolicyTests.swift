// DecodePolicyTests.swift — Pure policy dual-tested against TranscriberBuffer.tla.

import Testing
@testable import Chirp

@Suite("DecodePolicy")
struct DecodePolicyTests {

    @Test("commit source is always pending")
    func commitSourcePending() {
        #expect(DecodePolicy.commitSourceIsPending)
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
        // noiseFloor * multiplier ≈ 0.02 * 2.5 = 0.05
        #expect(abs(t - 0.02 * DecodePolicy.energyFloorMultiplier) < 0.02)
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

    @Test("energy floor constants are dual-testable")
    func energyFloorConstants() {
        #expect(DecodePolicy.energyMinFloor == DecodePolicy.energyThreshold)
        #expect(DecodePolicy.energyFloorMultiplier == 2.5)
        #expect(DecodePolicy.energyNoisePercentile > 0 && DecodePolicy.energyNoisePercentile < 0.5)
        #expect(DecodePolicy.energyFloorMinFrames >= 2)
    }
}
