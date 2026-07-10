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
}
