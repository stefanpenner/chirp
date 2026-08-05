// SystemSpeechAvailability.swift — Gate for Apple SpeechAnalyzer trial path.
// Pure version checks are dual-testable; runtime uses #available + OS major ≥ 26.
// Default product path remains Parakeet/sherpa; this only enables optional AI modes.

import Foundation

/// Availability for `TranscriptionMode.systemSpeech` (SpeechAnalyzer / SpeechTranscriber).
public enum SystemSpeechAvailability: Sendable {
    /// First macOS major that ships SpeechAnalyzer.
    public static let minimumMajorVersion = 26

    /// Pure OS gate (injectable for tests).
    public static func isOSSupported(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        version.majorVersion >= minimumMajorVersion
    }

    /// Runtime: OS version + Speech framework symbols available on this build.
    public static var isAvailable: Bool {
        guard isOSSupported() else { return false }
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Short reason when unavailable (settings / logs).
    public static var unavailableReason: String? {
        if isAvailable { return nil }
        if !isOSSupported() {
            return "Requires macOS \(minimumMajorVersion)+ (SpeechAnalyzer)"
        }
        return "SpeechAnalyzer unavailable on this build"
    }
}
