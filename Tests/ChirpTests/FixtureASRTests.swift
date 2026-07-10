// FixtureASRTests.swift — Always-on real-audio ASR smoke.
//
// Uses committed hello_world.wav + Parakeet when present.
// Machines without the model skip (stay green). With model: hard WER fail.
//
// Run: bazel test //:FixtureASRTests --test_output=errors

import Testing
import Foundation
@testable import Chirp

@Suite("Fixture ASR smoke (hello_world.wav)")
struct FixtureASRTests {

    // MARK: - Model discovery (same paths as AudioCorpusPipelineTests)

    private static func findModelPaths() -> ModelPaths? {
        let fm = FileManager.default
        let modelDir: String
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           fm.fileExists(atPath: envDir + "/encoder.int8.onnx") {
            modelDir = envDir
        } else {
            let appSupportCandidates: [String] = [
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first?.appendingPathComponent("Chirp/models").path,
                ProcessInfo.processInfo.environment["HOME"]
                    .map { "\($0)/Library/Application Support/Chirp/models" },
                NSHomeDirectory() + "/Library/Application Support/Chirp/models",
            ].compactMap { $0 }

            let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
            var found: String?
            for base in appSupportCandidates {
                let candidate = "\(base)/\(modelName)"
                if fm.fileExists(atPath: "\(candidate)/encoder.int8.onnx") {
                    found = candidate
                    break
                }
            }
            // Repo-local models/ (setup.sh / SPM dev)
            let repoCandidates = [
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent() // ChirpTests
                    .deletingLastPathComponent() // Tests
                    .deletingLastPathComponent() // repo root
                    .appendingPathComponent("models/\(modelName)").path,
                "models/\(modelName)",
            ]
            for candidate in repoCandidates {
                if fm.fileExists(atPath: "\(candidate)/encoder.int8.onnx") {
                    found = candidate
                    break
                }
            }
            guard let dir = found else { return nil }
            modelDir = dir
        }

        let vadCandidates: [String] = [
            ProcessInfo.processInfo.environment["CHIRP_VAD_PATH"],
            Bundle.main.resourcePath.map { "\($0)/silero_vad.onnx" },
            Bundle.main.executablePath.flatMap { execPath in
                var url = URL(fileURLWithPath: execPath)
                while !url.lastPathComponent.hasSuffix(".runfiles") {
                    let prev = url
                    url = url.deletingLastPathComponent()
                    if url == prev { return nil }
                }
                return url.appendingPathComponent("+deps+silero_vad/file/silero_vad.onnx").path
            },
            "\(modelDir)/silero_vad.onnx",
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("models/silero_vad.onnx").path,
            "models/silero_vad.onnx",
        ].compactMap { $0 }

        for vad in vadCandidates {
            if fm.fileExists(atPath: vad) {
                return ModelPaths(modelDir: modelDir, vadPath: vad)
            }
        }
        return nil
    }

    private static func findHelloWorldWAV() -> String? {
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("hello_world.wav").path,
            "Tests/ChirpTests/hello_world.wav",
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Feed samples in ~85 ms chunks through Transcriber; return text + wall time.
    private static func transcribe(
        samples: [Float],
        paths: ModelPaths
    ) async throws -> (text: String, elapsed: TimeInterval) {
        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize")
            return ("", 0)
        }

        TextPostProcessor.resetSessionFormatState()

        let t0 = Date()
        let chunkSize = DecodePolicy.streamChunkSamples
        var segments: [String] = []
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let segs = await transcriber.feedAudio(samples: chunk)
            segments.append(contentsOf: segs)
        }
        let flushed = await transcriber.flush()
        if !flushed.isEmpty { segments.append(flushed) }
        let elapsed = Date().timeIntervalSince(t0)

        var processed: [String] = []
        for seg in segments {
            let p = TextPostProcessor.process(seg)
            if !p.isEmpty { processed.append(p) }
        }
        let hyp = processed.joined(separator: " ")
        return (hyp, elapsed)
    }

    // MARK: - Tests

    @Test("Fixture WAV hello_world scores against expected phrase")
    func fixtureHelloWorldRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found — set CHIRP_MODEL_DIR / install Parakeet v3")
            return
        }
        guard let wavPath = Self.findHelloWorldWAV() else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try SpeechAudioGenerator.loadWAV(path: wavPath)
        let (hyp, elapsed) = try await Self.transcribe(
            samples: SpeechAudioGenerator.withTrailingSilence(samples, seconds: 0.5),
            paths: paths
        )
        let score = TranscriptionScoring.score(
            id: "fixture_hello_world",
            reference: "hello world",
            hypothesis: hyp
        )
        print(score.summaryLine)
        print(String(format: "fixture decode=%.2fs", elapsed))

        // Fixture is committed TTS of "hello world" — require low WER.
        #expect(
            score.wer <= 0.5,
            "fixture WER \(score.wer) too high: \"\(hyp)\""
        )
        let norm = TranscriptionScoring.normalize(hyp)
        #expect(
            norm.contains("hello") && norm.contains("world"),
            "fixture missing expected words: \"\(hyp)\""
        )
    }
}
