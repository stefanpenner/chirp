// SpeechAudioGenerator.swift — Synthesize or load 16 kHz mono Float32 audio for tests.
// Generation uses macOS `say` + `afconvert` so corpus tests exercise real acoustic input
// without committing large binary fixtures for every phrase.

import Foundation
import AVFoundation

enum SpeechAudioError: Error, CustomStringConvertible {
    case sayFailed(String)
    case convertFailed(String)
    case loadFailed(String)
    case noDataChunk
    case unsupportedFormat(String)

    var description: String {
        switch self {
        case .sayFailed(let m): return "say failed: \(m)"
        case .convertFailed(let m): return "afconvert failed: \(m)"
        case .loadFailed(let m): return "load failed: \(m)"
        case .noDataChunk: return "WAV has no data chunk"
        case .unsupportedFormat(let m): return "unsupported WAV: \(m)"
        }
    }
}

enum SpeechAudioGenerator {
    static let sampleRate: Double = 16_000

    // MARK: - Synthetic speech (macOS TTS)

    /// Generate 16 kHz mono Float32 samples for `text` via system TTS.
    /// - Parameters:
    ///   - text: phrase to speak
    ///   - voice: `say -v` voice name (default Samantha / system default)
    ///   - rate: words per minute for `say` (-r). 180 is clear and dictation-like.
    static func synthesize(
        text: String,
        voice: String? = "Samantha",
        rate: Int = 180
    ) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-tts-\(UUID().uuidString)")
        let aiffURL = tmp.appendingPathExtension("aiff")
        let wavURL = tmp.appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: aiffURL)
            try? FileManager.default.removeItem(at: wavURL)
        }

        // say -o writes AIFF/CAF; then afconvert → 16 kHz LE float mono WAV
        var sayArgs = ["-o", aiffURL.path, "-r", "\(rate)"]
        if let voice {
            sayArgs += ["-v", voice]
        }
        sayArgs.append(text)

        try run("/usr/bin/say", arguments: sayArgs, errorDomain: "say")
        try run(
            "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE",
                "-d", "LEF32@16000",
                "-c", "1",
                aiffURL.path,
                wavURL.path,
            ],
            errorDomain: "afconvert"
        )

        return try loadWAV(path: wavURL.path)
    }

    /// Silence of the given duration (seconds) at 16 kHz.
    static func silence(seconds: Double) -> [Float] {
        let n = max(0, Int(seconds * sampleRate))
        return [Float](repeating: 0, count: n)
    }

    /// Append trailing silence so VAD can endpoint (default 0.7s ≥ min_silence 0.5s).
    static func withTrailingSilence(_ samples: [Float], seconds: Double = 0.7) -> [Float] {
        samples + silence(seconds: seconds)
    }

    /// Mix white-ish uniform noise at the given SNR (dB).
    static func addNoise(to samples: [Float], snrDB: Float, seed: UInt64 = 42) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let signalPower = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let signalRMS = sqrtf(max(signalPower, 1e-12))
        let noiseRMS = signalRMS / powf(10, snrDB / 20)
        let scale = noiseRMS * sqrtf(3)
        var rng = SeededRNG(seed: seed)
        return samples.map { sample in
            let noise = (rng.nextFloat() * 2 - 1) * scale
            return sample + noise
        }
    }

    // MARK: - WAV I/O

    /// Load mono 16 kHz WAV (Float32 or Int16 PCM). Finds the data chunk.
    static func loadWAV(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 44 else { throw SpeechAudioError.loadFailed("file too short") }

        // Parse fmt chunk for bits/format
        guard let fmtRange = data.range(of: Data("fmt ".utf8)) else {
            throw SpeechAudioError.unsupportedFormat("no fmt chunk")
        }
        let fmtStart = fmtRange.lowerBound
        // fmt chunk: 4 id + 4 size + payload
        let audioFormat = readUInt16(data, at: fmtStart + 8)      // 1=PCM, 3=IEEE float
        let numChannels = readUInt16(data, at: fmtStart + 10)
        let bitsPerSample = readUInt16(data, at: fmtStart + 22)

        guard numChannels == 1 else {
            throw SpeechAudioError.unsupportedFormat("expected mono, got \(numChannels) ch")
        }

        guard let dataRange = data.range(of: Data("data".utf8)) else {
            throw SpeechAudioError.noDataChunk
        }
        let audioStart = dataRange.lowerBound + 8
        let dataSize = Int(readUInt32(data, at: dataRange.lowerBound + 4))
        let audioEnd = min(data.count, audioStart + dataSize)
        guard audioEnd > audioStart else { throw SpeechAudioError.loadFailed("empty data") }

        let audioData = data.subdata(in: audioStart..<audioEnd)

        if audioFormat == 3 && bitsPerSample == 32 {
            // IEEE float32
            let count = audioData.count / MemoryLayout<Float>.size
            return audioData.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: Float.self).prefix(count))
            }
        }

        if audioFormat == 1 && bitsPerSample == 16 {
            let count = audioData.count / MemoryLayout<Int16>.size
            return audioData.withUnsafeBytes { ptr in
                let ints = ptr.bindMemory(to: Int16.self).prefix(count)
                return ints.map { Float($0) / Float(Int16.max) }
            }
        }

        throw SpeechAudioError.unsupportedFormat(
            "format=\(audioFormat) bits=\(bitsPerSample) (need float32 or int16 mono)"
        )
    }

    // MARK: - Process helpers

    private static func run(_ launchPath: String, arguments: [String], errorDomain: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            if errorDomain == "say" {
                throw SpeechAudioError.sayFailed(errText.isEmpty ? "exit \(proc.terminationStatus)" : errText)
            }
            throw SpeechAudioError.convertFailed(errText.isEmpty ? "exit \(proc.terminationStatus)" : errText)
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}

/// Tiny deterministic RNG for reproducible noise.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }

    mutating func nextFloat() -> Float {
        Float(next() % 10_000) / 10_000.0
    }
}
