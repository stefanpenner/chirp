// CloudSTT.swift — Cloud speech-to-text client protocol + WAV encoder.
// Concrete implementations live in Providers/.

import Foundation

// MARK: - Protocol

protocol STTClient: Sendable {
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String
}

// MARK: - Errors

enum STTError: Error, LocalizedError {
    case noAPIKey
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    case emptyAudio
    /// Apple SpeechAnalyzer path unavailable or locale/model missing.
    case systemSpeechUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidResponse: return "Invalid response from API"
        case .emptyAudio: return "No audio to transcribe"
        case .systemSpeechUnavailable(let reason): return "Apple Speech unavailable: \(reason)"
        }
    }
}

// MARK: - WAV Encoder

/// Encodes raw Float32 PCM samples into a WAV file in memory.
/// Used by cloud STT providers that accept WAV uploads.
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = samples.count * bytesPerSample
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(littleEndian: UInt32(fileSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(littleEndian: UInt32(16))               // chunk size
        data.append(littleEndian: UInt16(1))                // PCM format
        data.append(littleEndian: UInt16(channels))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * channels * bytesPerSample)) // byte rate
        data.append(littleEndian: UInt16(channels * bytesPerSample))              // block align
        data.append(littleEndian: UInt16(bitsPerSample))

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(littleEndian: UInt32(dataSize))

        // Convert Float32 → Int16 PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            data.append(littleEndian: int16)
        }

        return data
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian value: Int16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
