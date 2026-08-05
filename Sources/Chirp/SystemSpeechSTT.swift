// SystemSpeechSTT.swift — Optional on-device STT via Apple SpeechAnalyzer (macOS 26+).
// Implements STTClient so rebuildPipeline can reuse CloudTranscriptionPipeline
// (batch on flush + local Parakeet peek). Default remains Parakeet/sherpa.
//
// SpeechAnalyzer types exist only in the macOS 26+ SDK. Builds against older
// SDKs (CI macos-15 / Xcode 16) must still compile — use a stub there.
// Full engine is compiled when the SpeechAnalyzer type is available.

import AVFoundation
import Foundation
import Speech

// MARK: - Client

/// On-device Apple SpeechAnalyzer STT. Opt-in via `TranscriptionMode.systemSpeech`.
struct SystemSpeechClient: STTClient {
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard !samples.isEmpty else { throw STTError.emptyAudio }
        guard SystemSpeechAvailability.isAvailable else {
            throw STTError.systemSpeechUnavailable(
                SystemSpeechAvailability.unavailableReason ?? "unavailable"
            )
        }
        return try await SystemSpeechEngine.transcribe(samples: samples, sampleRate: sampleRate)
    }
}

// MARK: - Engine

/// SpeechAnalyzer path when the SDK exposes the types; otherwise a clear error.
enum SystemSpeechEngine {
    static func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            return try await SystemSpeechEngine26.transcribe(samples: samples, sampleRate: sampleRate)
        }
        #endif
        throw STTError.systemSpeechUnavailable("SpeechAnalyzer requires macOS 26+")
    }
}

// SpeechTranscriber / SpeechAnalyzer ship with the macOS 26 SDK. When building
// against an older SDK those symbols are absent, so the real implementation is
// gated by a compile-time check on the OS availability attribute that only
// type-checks when the types exist.
//
// Xcode 26+ / macOS 26 SDK: full path.
// Older SDK: empty @available type-erased stub via unavailable API surface.

#if compiler(>=6.2)
@available(macOS 26.0, *)
private enum SystemSpeechEngine26 {
    static func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw STTError.systemSpeechUnavailable(
                "No SpeechTranscriber locale for \(Locale.current.identifier)"
            )
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-system-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let wav = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        try wav.write(to: url)
        let audioFile = try AVAudioFile(forReading: url)

        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )
        _ = analyzer

        var finalized = ""
        for try await result in transcriber.results {
            if result.isFinal {
                finalized += String(result.text.characters)
            }
        }

        return finalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#else
/// Stub when the toolchain/SDK lacks SpeechAnalyzer (e.g. Xcode 16 / macOS 15 SDK).
@available(macOS 26.0, *)
private enum SystemSpeechEngine26 {
    static func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        throw STTError.systemSpeechUnavailable(
            "SpeechAnalyzer not in this SDK (build with Xcode 26+ / macOS 26 SDK)"
        )
    }
}
#endif
