// AudioCorpusPipelineTests.swift — Generate real speech audio, pipe through the
// offline pipeline, score hypotheses with WER/CER, and rank the corpus.
//
// Requires Parakeet + Silero models (same discovery as TranscriberIntegrationTests).
// Run: bazel test //:TranscriberIntegrationTests --test_output=all

import Testing
import Foundation
@testable import Chirp

@Suite("Audio corpus pipeline (generated speech → ranked WER)")
struct AudioCorpusPipelineTests {

    // MARK: - Corpus

    /// Golden phrases: short, clear, ASCII-friendly for macOS TTS + Parakeet.
    /// Expected text is what we score against after ASR.
    private static let corpus: [(id: String, text: String)] = [
        ("hello_world", "hello world"),
        ("numbers", "the quick brown fox jumps over the lazy dog"),
        ("dictation", "please send the report by friday"),
        ("calendar", "schedule a meeting for three pm"),
        ("address", "open the document on my desktop"),
        ("short_ok", "okay"),
        ("question", "what time is the flight"),
        ("command", "create a new note"),
    ]

    /// Mean WER ceiling for clean TTS → Parakeet on this corpus.
    /// Tight enough to catch regressions (onset clips, bad post-process);
    /// loose enough for occasional TTS/ASR confusions (e.g. the/a).
    private static let maxMeanWER: Double = 0.15
    private static let maxMedianWER: Double = 0.10
    /// No single phrase may be a near-total miss on clean audio.
    private static let maxPerPhraseWER: Double = 0.50

    // MARK: - Model discovery (shared logic with TranscriberIntegrationTests)

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

    // MARK: - Pipeline runner

    /// Feed samples in ~85 ms chunks through Transcriber; return combined text.
    private static func transcribe(samples: [Float], paths: ModelPaths) async throws -> String {
        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize")
            return ""
        }

        let chunkSize = 1360 // ~85ms @ 16 kHz
        var segments: [String] = []
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let segs = await transcriber.feedAudio(samples: chunk)
            segments.append(contentsOf: segs)
        }
        let flushed = await transcriber.flush()
        if !flushed.isEmpty { segments.append(flushed) }

        // Apply same light post-process the product uses
        let raw = segments.joined(separator: " ")
        return TextPostProcessor.process(raw)
    }

    /// Full AppState path: MockAudioRecorder → pipeline → typed text.
    @MainActor
    private static func transcribeViaAppState(samples: [Float], paths: ModelPaths) async throws -> String {
        let transcriber = Transcriber()
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter,
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000

        // Offline + regex (incremental) — product-like default without T5 latency
        let mode = AIMode(
            name: "Corpus-Offline",
            transcriptionMode: .offline,
            postProcessingMode: .regex
        )
        var settings = AISettings()
        settings.modes = [mode]
        settings.activeModeID = mode.id
        state.aiSettings = settings
        state.rebuildPipeline()

        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize")
            return ""
        }
        state.status = .ready
        state.startRecording()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunkSize = 1360
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            recorder.lastOnSamples?(Array(samples[start..<end]))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        state.stopRecording()

        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if case .ready = state.status { break }
        }

        return state.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tests

    @Test("Synthesized speech corpus ranks under WER budget")
    func rankedCorpusClean() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found — set CHIRP_MODEL_DIR / install Parakeet v3")
            return
        }

        // Prefer a clear US English voice; fall back if missing.
        let voices = ["Samantha", "Alex", "Daniel", nil]
        var workingVoice: String? = "Samantha"
        for v in voices {
            do {
                _ = try SpeechAudioGenerator.synthesize(text: "test", voice: v)
                workingVoice = v
                break
            } catch {
                continue
            }
        }

        var pairs: [(id: String, reference: String, hypothesis: String)] = []

        for item in Self.corpus {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(
                    text: item.text,
                    voice: workingVoice
                )
            } catch {
                Issue.record("TTS failed for \(item.id): \(error)")
                continue
            }
            // Trailing silence so VAD can close the segment on flush
            let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
            #expect(samples.count > 1600, "Generated audio too short for \(item.id)")

            let hyp = try await Self.transcribe(samples: samples, paths: paths)
            pairs.append((id: item.id, reference: item.text, hypothesis: hyp))
            print("corpus[\(item.id)] ref=\"\(item.text)\" hyp=\"\(hyp)\" samples=\(samples.count)")
        }

        #expect(pairs.count >= 5, "Too few corpus items transcribed (TTS or model failure)")

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)

        #expect(
            ranking.meanWER <= Self.maxMeanWER,
            "mean WER \(ranking.meanWER) exceeds budget \(Self.maxMeanWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.medianWER <= Self.maxMedianWER,
            "median WER \(ranking.medianWER) exceeds budget \(Self.maxMedianWER)\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(
                s.wer <= Self.maxPerPhraseWER,
                "phrase \(s.id) WER \(s.wer) too high (hyp=\"\(s.hypothesis)\")"
            )
        }
    }

    @Test("AppState pipeline: generated audio → typed text ranked")
    @MainActor
    func rankedCorpusViaAppState() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        // Smaller subset for slower E2E path
        let subset = [
            ("e2e_hello", "hello world"),
            ("e2e_note", "create a new note"),
            ("e2e_meeting", "schedule a meeting for three pm"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in subset {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: "Samantha")
            } catch {
                // voice fallback
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: nil)
            }
            let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
            let hyp = try await Self.transcribeViaAppState(samples: samples, paths: paths)
            pairs.append((id: item.0, reference: item.1, hypothesis: hyp))
            print("e2e[\(item.0)] ref=\"\(item.1)\" hyp=\"\(hyp)\"")
        }

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)

        #expect(pairs.count == subset.count)
        #expect(
            ranking.meanWER <= 0.40,
            "E2E mean WER \(ranking.meanWER) exceeds 0.40\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(!s.hypothesis.isEmpty, "empty hypothesis for \(s.id)")
        }
    }

    @Test("Silence produces empty or near-empty transcription (rankable false-positive check)")
    func silenceIsClean() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        // 1.5s pure silence + trailing silence buffer
        let samples = SpeechAudioGenerator.silence(seconds: 1.5)
        let hyp = try await Self.transcribe(samples: samples, paths: paths)
        let score = TranscriptionScoring.score(
            id: "silence",
            reference: "",
            hypothesis: hyp
        )
        print("silence hyp=\"\(hyp)\" score=\(score.summaryLine)")

        // Empty reference: any non-empty hyp → WER 1.0. We require perfect silence.
        #expect(
            score.wer == 0,
            "Silence produced hallucination \"\(hyp)\" (WER=\(score.wer))"
        )
    }

    @Test("Noisy speech still ranks under relaxed WER budget")
    func rankedCorpusNoisy() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let phrases = [
            ("noise_hello", "hello world"),
            ("noise_fox", "the quick brown fox"),
            ("noise_note", "create a new note"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in phrases {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: "Samantha")
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: nil)
            }
            let noisy = SpeechAudioGenerator.addNoise(to: speech, snrDB: 15, seed: 7)
            let samples = SpeechAudioGenerator.withTrailingSilence(noisy, seconds: 0.8)
            let hyp = try await Self.transcribe(samples: samples, paths: paths)
            pairs.append((id: item.0, reference: item.1, hypothesis: hyp))
            print("noisy[\(item.0)] hyp=\"\(hyp)\"")
        }

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)

        // Relaxed budget under 15 dB SNR
        #expect(
            ranking.meanWER <= 0.55,
            "noisy mean WER \(ranking.meanWER) exceeds 0.55\n\(ranking.leaderboard)"
        )
    }

    @Test("Fixture WAV hello_world scores against expected phrase")
    func fixtureHelloWorldRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("hello_world.wav").path,
            "Tests/ChirpTests/hello_world.wav",
        ]
        guard let wavPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try SpeechAudioGenerator.loadWAV(path: wavPath)
        let hyp = try await Self.transcribe(
            samples: SpeechAudioGenerator.withTrailingSilence(samples, seconds: 0.5),
            paths: paths
        )
        let score = TranscriptionScoring.score(
            id: "fixture_hello_world",
            reference: "hello world",
            hypothesis: hyp
        )
        print(score.summaryLine)

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

    @Test("Generator produces non-empty float audio")
    func generatorSmoke() throws {
        // Always runnable — no model needed
        let samples = try SpeechAudioGenerator.synthesize(text: "hello", voice: "Samantha")
        #expect(samples.count > 1600)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.01, "synthesized audio is near-silent")
        let withPad = SpeechAudioGenerator.withTrailingSilence(samples, seconds: 0.5)
        #expect(withPad.count > samples.count)
    }
}
