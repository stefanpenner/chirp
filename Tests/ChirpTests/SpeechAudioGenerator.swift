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

    /// Soft speech: scale amplitude (e.g. 0.15 ≈ quiet talk / far mic).
    static func soften(_ samples: [Float], gain: Float = 0.15) -> [Float] {
        let g = max(0, min(gain, 1))
        return samples.map { $0 * g }
    }

    /// Muffled speech: simple one-pole low-pass (covers / pillows over mic).
    /// `alpha` closer to 1 → darker / more muffled (0.85–0.95 typical).
    static func muffle(_ samples: [Float], alpha: Float = 0.90) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let a = max(0.5, min(alpha, 0.99))
        var y: Float = 0
        return samples.map { x in
            y = a * y + (1 - a) * x
            return y
        }
    }

    /// Pink-ish background (1/f-ish via leaky integrator on white noise), mixed at SNR.
    /// More realistic room/HVAC than pure white for dictation stress tests.
    static func addRoomNoise(to samples: [Float], snrDB: Float, seed: UInt64 = 99) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let signalPower = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let signalRMS = sqrtf(max(signalPower, 1e-12))
        let noiseRMS = signalRMS / powf(10, snrDB / 20)
        var rng = SeededRNG(seed: seed)
        var pink: Float = 0
        var noise = [Float](repeating: 0, count: samples.count)
        var power: Float = 0
        for i in 0..<samples.count {
            let white = rng.nextFloat() * 2 - 1
            pink = 0.95 * pink + 0.05 * white
            noise[i] = pink
            power += pink * pink
        }
        let rms = sqrtf(max(power / Float(samples.count), 1e-12))
        let scale = noiseRMS / rms
        return zip(samples, noise).map { $0 + $1 * scale }
    }

    /// Named acoustic conditions for graded voice quality tests.
    enum VoiceCondition: String, CaseIterable, Sendable {
        case clean
        case soft
        case muffled
        case softMuffled
        case noisyWhite15
        case noisyRoom12
        /// Soft + muffled + room noise — hard but realistic desk-fan / far-mic.
        case harshDesk

        var label: String { rawValue }

        /// Apply this condition to clean TTS samples (no trailing silence).
        func apply(to samples: [Float]) -> [Float] {
            switch self {
            case .clean:
                return samples
            case .soft:
                return SpeechAudioGenerator.soften(samples, gain: 0.15)
            case .muffled:
                return SpeechAudioGenerator.muffle(samples, alpha: 0.92)
            case .softMuffled:
                return SpeechAudioGenerator.muffle(
                    SpeechAudioGenerator.soften(samples, gain: 0.18),
                    alpha: 0.90
                )
            case .noisyWhite15:
                return SpeechAudioGenerator.addNoise(to: samples, snrDB: 15, seed: 7)
            case .noisyRoom12:
                return SpeechAudioGenerator.addRoomNoise(to: samples, snrDB: 12, seed: 11)
            case .harshDesk:
                let soft = SpeechAudioGenerator.soften(samples, gain: 0.20)
                let muff = SpeechAudioGenerator.muffle(soft, alpha: 0.88)
                return SpeechAudioGenerator.addRoomNoise(to: muff, snrDB: 10, seed: 13)
            }
        }
    }

    /// Peak absolute amplitude (for soft/muffle unit checks).
    static func peakAmplitude(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
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
