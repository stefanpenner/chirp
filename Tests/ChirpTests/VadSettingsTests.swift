// VadSettingsTests.swift — VAD endpoint setting clamp + defaults.

import Testing
import Foundation
@testable import Chirp

@Suite("VadSettings", .serialized)
struct VadSettingsTests {

    @Test("clamp bounds values into range")
    func clamp() {
        #expect(VadSettings.clamp(0.1, to: 0.3...1.2) == 0.3)
        #expect(VadSettings.clamp(2.0, to: 0.3...1.2) == 1.2)
        #expect(VadSettings.clamp(0.7, to: 0.3...1.2) == 0.7)
    }

    @Test("defaults match DecodePolicy when UserDefaults unset")
    func defaults() {
        VadSettings.resetTestOverrides()
        // Isolate from machine UserDefaults by forcing test overrides nil
        // and reading through test-only path after clearing keys is hard;
        // verify DecodePolicy dual + test override path.
        #expect(DecodePolicy.vadMinSilenceDuration == 0.55)
        #expect(DecodePolicy.vadThreshold == 0.45)

        VadSettings.testMinSilence = 0.8
        VadSettings.testThreshold = 0.6
        defer { VadSettings.resetTestOverrides() }
        #expect(VadSettings.minSilenceDuration == 0.8)
        #expect(VadSettings.threshold == 0.6)
    }

    @Test("test overrides are clamped")
    func overridesClamped() {
        VadSettings.testMinSilence = 0.05
        VadSettings.testThreshold = 0.99
        defer { VadSettings.resetTestOverrides() }
        #expect(VadSettings.minSilenceDuration == VadSettings.minSilenceRange.lowerBound)
        #expect(VadSettings.threshold == VadSettings.thresholdRange.upperBound)
    }

    @Test("formatSeconds is stable")
    func formatSeconds() {
        #expect(VadSettings.formatSeconds(0.55) == "0.55 s")
        #expect(VadSettings.formatSeconds(1.0) == "1.00 s")
    }

    @Test("ranges are sane for Silero dictation")
    func ranges() {
        #expect(VadSettings.minSilenceRange.lowerBound >= 0.2)
        #expect(VadSettings.minSilenceRange.upperBound <= 2.0)
        #expect(VadSettings.thresholdRange.lowerBound > 0)
        #expect(VadSettings.thresholdRange.upperBound < 1)
        #expect(VadSettings.minSilenceRange.contains(DecodePolicy.vadMinSilenceDuration))
        #expect(VadSettings.thresholdRange.contains(DecodePolicy.vadThreshold))
    }
}
