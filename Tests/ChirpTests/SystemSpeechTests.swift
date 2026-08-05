// SystemSpeechTests.swift — Availability + mode wiring for Apple Speech trial path.
// Does not force SpeechAnalyzer inference (model download / locale assets vary).

import Foundation
import Testing
@testable import Chirp

@Suite("SystemSpeechAvailability")
struct SystemSpeechAvailabilityTests {

    @Test("OS gate rejects pre-26 majors")
    func rejectsOlderOS() {
        #expect(!SystemSpeechAvailability.isOSSupported(
            version: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        ))
        #expect(!SystemSpeechAvailability.isOSSupported(
            version: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0)
        ))
    }

    @Test("OS gate accepts 26+")
    func acceptsMacOS26() {
        #expect(SystemSpeechAvailability.isOSSupported(
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ))
        #expect(SystemSpeechAvailability.isOSSupported(
            version: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)
        ))
    }

    @Test("runtime availability matches host OS major")
    func runtimeMatchesHost() {
        let host = ProcessInfo.processInfo.operatingSystemVersion
        let expected = host.majorVersion >= SystemSpeechAvailability.minimumMajorVersion
        // On this machine we are on macOS 26+; still assert pure consistency.
        #expect(SystemSpeechAvailability.isOSSupported(version: host) == expected)
        if expected {
            #expect(SystemSpeechAvailability.isAvailable)
            #expect(SystemSpeechAvailability.unavailableReason == nil)
        } else {
            #expect(!SystemSpeechAvailability.isAvailable)
            #expect(SystemSpeechAvailability.unavailableReason != nil)
        }
    }
}

@Suite("TranscriptionMode systemSpeech")
struct TranscriptionModeSystemSpeechTests {

    @Test("caseIterable includes systemSpeech without dropping defaults")
    func allCases() {
        let raw = TranscriptionMode.allCases.map(\.rawValue)
        #expect(raw.contains("offline"))
        #expect(raw.contains("cloud"))
        #expect(raw.contains("systemSpeech"))
    }

    @Test("display names")
    func displayNames() {
        #expect(TranscriptionMode.offline.displayName == "Offline")
        #expect(TranscriptionMode.cloud.displayName == "Cloud STT")
        #expect(TranscriptionMode.systemSpeech.displayName == "Apple Speech")
    }

    @Test("AIMode codable round-trip preserves systemSpeech")
    func modeCodable() throws {
        let mode = AIMode(
            name: "Apple Speech trial",
            transcriptionMode: .systemSpeech,
            postProcessingMode: .regex
        )
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(AIMode.self, from: data)
        #expect(decoded.transcriptionMode == .systemSpeech)
        #expect(decoded.name == "Apple Speech trial")
        #expect(decoded.postProcessingMode == .regex)
    }

    @Test("unknown transcriptionMode decode fails closed (no silent offline swap)")
    func unknownModeFailsDecode() {
        let json = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"x","transcriptionMode":"fluidAudio","postProcessingMode":"regex"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AIMode.self, from: json)
        }
    }

    @Test("empty audio throws emptyAudio")
    func emptyAudio() async {
        let client = SystemSpeechClient()
        await #expect(throws: STTError.self) {
            try await client.transcribe(samples: [], sampleRate: 16000)
        }
    }
}
