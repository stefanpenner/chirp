// VadSettings.swift — User-tunable Silero VAD endpointing.
// Defaults match DecodePolicy; values clamped for safe range.
// Dual-tested via VadSettingsTests (clamp + defaults).

import Foundation

enum VadSettings {
    static let minSilenceKey = "chirp.vad.minSilenceSeconds"
    static let thresholdKey = "chirp.vad.threshold"

    /// Test overrides (nil = read UserDefaults / defaults).
    nonisolated(unsafe) static var testMinSilence: Float?
    nonisolated(unsafe) static var testThreshold: Float?

    /// Allowed pause length before a new phrase is committed (seconds).
    static let minSilenceRange: ClosedRange<Float> = 0.30...1.20

    /// Speech probability threshold range (higher = less sensitive to noise).
    static let thresholdRange: ClosedRange<Float> = 0.25...0.75

    static func resetTestOverrides() {
        testMinSilence = nil
        testThreshold = nil
    }

    /// Clamp raw value into range (pure; dual of VadEndpoint.tla).
    static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Silence after speech before VAD ends a segment (seconds).
    /// Default: DecodePolicy.vadMinSilenceDuration (0.55).
    static var minSilenceDuration: Float {
        get {
            if let t = testMinSilence { return clamp(t, to: minSilenceRange) }
            if UserDefaults.standard.object(forKey: minSilenceKey) == nil {
                return DecodePolicy.vadMinSilenceDuration
            }
            let raw = UserDefaults.standard.float(forKey: minSilenceKey)
            return clamp(raw, to: minSilenceRange)
        }
        set {
            UserDefaults.standard.set(clamp(newValue, to: minSilenceRange), forKey: minSilenceKey)
        }
    }

    /// Silero speech probability threshold.
    /// Default: DecodePolicy.vadThreshold (0.45).
    static var threshold: Float {
        get {
            if let t = testThreshold { return clamp(t, to: thresholdRange) }
            if UserDefaults.standard.object(forKey: thresholdKey) == nil {
                return DecodePolicy.vadThreshold
            }
            let raw = UserDefaults.standard.float(forKey: thresholdKey)
            return clamp(raw, to: thresholdRange)
        }
        set {
            UserDefaults.standard.set(clamp(newValue, to: thresholdRange), forKey: thresholdKey)
        }
    }

    /// Human-readable pause label for settings (e.g. "0.55 s").
    static func formatSeconds(_ value: Float) -> String {
        String(format: "%.2f s", value)
    }
}
