// SystemSpeechSTT.swift — Optional on-device STT via Apple SpeechAnalyzer (macOS 26+).
// Implements STTClient so rebuildPipeline can reuse CloudTranscriptionPipeline
// (batch on flush + local Parakeet peek). Default remains Parakeet/sherpa.

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
        if #available(macOS 26.0, *) {
            return try await SystemSpeechEngine.transcribe(samples: samples, sampleRate: sampleRate)
        }
        throw STTError.systemSpeechUnavailable("SpeechAnalyzer requires macOS 26+")
    }
}

// MARK: - Engine (macOS 26+)

@available(macOS 26.0, *)
enum SystemSpeechEngine {
    static func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw STTError.systemSpeechUnavailable("No SpeechTranscriber locale for \(Locale.current.identifier)")
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Download OS speech assets if missing (no-op when already installed).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // Write batch audio to a temp WAV; file path is simpler than live stream conversion.
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
        _ = analyzer // retain for session lifetime while consuming results

        var finalized = ""
        for try await result in transcriber.results {
            if result.isFinal {
                finalized += String(result.text.characters)
            }
        }

        return finalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
