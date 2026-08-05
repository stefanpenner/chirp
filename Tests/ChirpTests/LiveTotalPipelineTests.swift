// LiveTotalPipelineTests.swift — Common speech TTS → stream pipeline → score live peeks + total.
//
// Per phrase:
//   text → macOS `say`/`afconvert` (16 kHz mono Float32)
//        → Transcriber feedAudio in ~85 ms chunks
//        → peekTranscription on a cadence (live / partial)
//        → flush (total)
//        → TextPostProcessor
//        → LiveTotalScore (WER / majorWER / token P/R for live and total)
//
// Requires Parakeet + Silero (same discovery as AudioCorpusPipelineTests).
// Run:
//   bazel test //:LiveTotalPipelineTests --test_output=all
//   bazel test //:AudioCorpusPipelineTests --test_filter=LiveTotal --test_output=all

import Testing
import Foundation
@testable import Chirp

@Suite("Live + total pipeline (generated speech → peek + flush scored)", .serialized)
struct LiveTotalPipelineTests {

    // MARK: - Common speech corpus

    /// Everyday dictation phrases (ASCII-friendly for macOS TTS + Parakeet).
    private static let commonSpeech: [(id: String, text: String)] = [
        ("lt_hello", "hello world"),
        ("lt_thanks", "thanks for your help"),
        ("lt_note", "create a new note"),
        ("lt_meeting", "schedule a meeting for three pm"),
        ("lt_email", "send an email to the team"),
        ("lt_weather", "what is the weather tomorrow"),
        ("lt_report", "please send the report by friday"),
        // Avoid ultra-short single tokens ("okay") — DecodeReject can drop final flush
        // while peeks still show the word (live≠total gap is intentional to catch).
        ("lt_yes", "yes please"),
    ]

    /// Total (final) budgets — clean TTS, full utterance after flush.
    private static let maxMeanTotalMajorWER: Double = 0.15
    private static let maxMeanTotalWER: Double = 0.20
    private static let maxPerPhraseTotalMajorWER: Double = 0.40
    private static let minMeanTotalRecall: Double = 0.70

    /// Live (last non-empty peek) budgets — partial; looser WER, tight precision.
    private static let maxMeanLiveMajorWER: Double = 0.45
    private static let minMeanLivePrecision: Double = 0.55
    /// At least this fraction of phrases must produce ≥1 non-empty peek.
    private static let minLivePeekPhraseRate: Double = 0.50

    /// Peek every N stream chunks (~85 ms each) while feeding.
    private static let peekEveryChunks = 4

    // MARK: - Model discovery

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
            let repoCandidates = [
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
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

    private static func workingVoice() -> String? {
        for v in ["Samantha", "Alex", "Daniel", "Karen"] {
            if (try? SpeechAudioGenerator.synthesize(text: "test", voice: v)) != nil {
                return v
            }
        }
        if (try? SpeechAudioGenerator.synthesize(text: "test", voice: nil)) != nil {
            return nil
        }
        return nil
    }

    // MARK: - Stream runner (live peeks + total)

    /// Feed samples in stream chunks; peek on a cadence; flush at end.
    /// Returns scored live + total for `reference`.
    private static func runLiveTotal(
        id: String,
        reference: String,
        samples: [Float],
        paths: ModelPaths
    ) async throws -> LiveTotalScore {
        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize for \(id)")
            return TranscriptionScoring.scoreLiveTotal(
                id: id, reference: reference, livePeeks: [], totalHypothesis: ""
            )
        }

        TextPostProcessor.resetSessionFormatState()

        let chunkSize = DecodePolicy.streamChunkSamples
        var commits: [String] = []
        var livePeeks: [String] = []
        var chunkIndex = 0
        let t0 = Date()

        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let segs = await transcriber.feedAudio(samples: chunk)
            if !segs.isEmpty {
                commits.append(contentsOf: segs)
            }
            chunkIndex += 1
            // Live speculative path (product peek loop cadence ~250ms ≈ 3 chunks)
            if chunkIndex % peekEveryChunks == 0 {
                if let peek = await transcriber.peekTranscription(), !peek.isEmpty {
                    livePeeks.append(peek)
                }
            }
        }

        // One last peek before flush (captures near-complete utterance)
        if let peek = await transcriber.peekTranscription(), !peek.isEmpty {
            livePeeks.append(peek)
        }

        let flushed = await transcriber.flush()
        if !flushed.isEmpty { commits.append(flushed) }
        let elapsed = Date().timeIntervalSince(t0)

        // Same light post-process as product (per segment)
        var processed: [String] = []
        for seg in commits {
            let p = TextPostProcessor.process(seg)
            if !p.isEmpty { processed.append(p) }
        }
        let totalHyp = processed.joined(separator: " ")
        // If final path dropped text but live peeks succeeded, score total as empty
        // (product gap) — do not silently promote live into total.
        let audioSec = Double(samples.count) / Double(DecodePolicy.sampleRate)
        let rtf = audioSec > 0 ? elapsed / audioSec : 0
        if totalHyp.isEmpty, let lastLive = livePeeks.last, !lastLive.isEmpty {
            print("WARN[\(id)]: empty TOTAL with non-empty LIVE=\"\(lastLive)\" (flush/commit gap)")
        }

        let score = TranscriptionScoring.scoreLiveTotal(
            id: id,
            reference: reference,
            livePeeks: livePeeks,
            totalHypothesis: totalHyp,
            midCommitCount: max(0, commits.count - (flushed.isEmpty ? 0 : 1))
        )

        print(String(format:
            "live-total[%@] peeks=%d commits=%d audio=%.2fs decode=%.2fs RTF=%.2f",
            id, livePeeks.count, commits.count, audioSec, elapsed, rtf))
        print(score.summaryLine)
        return score
    }

    private static func synthesizePhrase(_ text: String, voice: String?) throws -> [Float] {
        let speech: [Float]
        if let voice {
            do {
                speech = try SpeechAudioGenerator.synthesize(text: text, voice: voice)
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: text, voice: nil)
            }
        } else {
            speech = try SpeechAudioGenerator.synthesize(text: text, voice: nil)
        }
        return SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
    }

    // MARK: - Tests

    @Test("Common speech: live peeks + total hyp under dual budgets")
    func commonSpeechLiveAndTotal() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found — set CHIRP_MODEL_DIR / install Parakeet v3")
            return
        }

        // Score content words; leave relative-date ITN off for "tomorrow".
        FormatSettings.testExpandRelativeDates = false
        FormatSettings.testExpandNumberedLists = false
        FormatSettings.testExpandBullets = false
        defer { FormatSettings.resetTestOverrides() }

        let voice = Self.workingVoice()
        var results: [LiveTotalScore] = []

        for item in Self.commonSpeech {
            let samples: [Float]
            do {
                samples = try Self.synthesizePhrase(item.text, voice: voice)
            } catch {
                Issue.record("TTS failed for \(item.id): \(error)")
                continue
            }
            #expect(samples.count > 1600, "audio too short for \(item.id)")
            let score = try await Self.runLiveTotal(
                id: item.id,
                reference: item.text,
                samples: samples,
                paths: paths
            )
            results.append(score)
        }

        #expect(results.count >= 5, "too few phrases ran (TTS/model failure)")

        let ranking = TranscriptionScoring.rankLiveTotal(results)
        print("\n========== LIVE + TOTAL RANKED REPORT ==========")
        print(ranking.leaderboard)
        print("================================================\n")

        let withLive = results.filter { !$0.livePeeks.isEmpty }.count
        let liveRate = Double(withLive) / Double(results.count)
        print(String(format: "live peek phrase rate=%.0f%% (%d/%d)", liveRate * 100, withLive, results.count))

        // --- Total (final) ---
        #expect(
            ranking.meanTotalMajorWER <= Self.maxMeanTotalMajorWER,
            "mean TOTAL majorWER \(ranking.meanTotalMajorWER) exceeds \(Self.maxMeanTotalMajorWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanTotalWER <= Self.maxMeanTotalWER,
            "mean TOTAL WER \(ranking.meanTotalWER) exceeds \(Self.maxMeanTotalWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanTotalRecall >= Self.minMeanTotalRecall,
            "mean TOTAL recall \(ranking.meanTotalRecall) below \(Self.minMeanTotalRecall)\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(
                !s.totalHypothesis.isEmpty,
                "empty TOTAL hyp for \(s.id)"
            )
            #expect(
                s.total.majorWER <= Self.maxPerPhraseTotalMajorWER,
                "phrase \(s.id) TOTAL majorWER \(s.total.majorWER) too high: \"\(s.totalHypothesis)\""
            )
        }

        // --- Live (partial) ---
        #expect(
            liveRate >= Self.minLivePeekPhraseRate,
            "live peek phrase rate \(liveRate) below \(Self.minLivePeekPhraseRate) — peeks not firing"
        )
        // Only score live WER/precision on phrases that produced peeks
        let liveScores = results.filter { !$0.livePeeks.isEmpty }
        if !liveScores.isEmpty {
            let liveRank = TranscriptionScoring.rankLiveTotal(liveScores)
            #expect(
                liveRank.meanLiveMajorWER <= Self.maxMeanLiveMajorWER,
                "mean LIVE majorWER \(liveRank.meanLiveMajorWER) exceeds \(Self.maxMeanLiveMajorWER)\n\(liveRank.leaderboard)"
            )
            #expect(
                liveRank.meanLivePrecision >= Self.minMeanLivePrecision,
                "mean LIVE precision \(liveRank.meanLivePrecision) below \(Self.minMeanLivePrecision) (hallucinations?)\n\(liveRank.leaderboard)"
            )
        }
    }

    @Test("Fixture WAV: live + total scored against hello world")
    func fixtureHelloWorldLiveTotal() async throws {
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

        let raw = try SpeechAudioGenerator.loadWAV(path: wavPath)
        let samples = SpeechAudioGenerator.withTrailingSilence(raw, seconds: 0.5)
        let score = try await Self.runLiveTotal(
            id: "fixture_hello_live_total",
            reference: "hello world",
            samples: samples,
            paths: paths
        )
        print(score.summaryLine)

        #expect(!score.totalHypothesis.isEmpty, "empty total for fixture")
        #expect(
            score.total.majorWER <= 0.50,
            "fixture TOTAL majorWER \(score.total.majorWER): \"\(score.totalHypothesis)\""
        )
        let norm = TranscriptionScoring.normalize(score.totalHypothesis)
        #expect(
            norm.contains("hello") && norm.contains("world"),
            "fixture total missing words: \"\(score.totalHypothesis)\""
        )
        // Live is best-effort on short fixture; if present, precision should be sane
        if !score.livePeeks.isEmpty {
            #expect(
                score.livePrecision >= 0.40,
                "fixture LIVE precision \(score.livePrecision) too low: \"\(score.liveHypothesis)\""
            )
        }
    }

    @Test("AppState path: generated speech → typed total + speculative live sample")
    @MainActor
    func appStateLiveAndTotal() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let phrases = [
            ("as_hello", "hello world"),
            ("as_note", "create a new note"),
            ("as_meet", "schedule a meeting for three pm"),
        ]

        var results: [LiveTotalScore] = []

        for item in phrases {
            let samples: [Float]
            do {
                samples = try Self.synthesizePhrase(item.1, voice: "Samantha")
            } catch {
                samples = try Self.synthesizePhrase(item.1, voice: nil)
            }

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

            let mode = AIMode(
                name: "LiveTotal-Offline",
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
                Issue.record("init failed for \(item.0)")
                continue
            }

            state.status = .ready
            state.startRecording()
            try await Task.sleep(nanoseconds: 50_000_000)

            var livePeeks: [String] = []
            let chunkSize = DecodePolicy.streamChunkSamples
            var i = 0
            for start in stride(from: 0, to: samples.count, by: chunkSize) {
                let end = min(start + chunkSize, samples.count)
                recorder.lastOnSamples?(Array(samples[start..<end]))
                try await Task.sleep(nanoseconds: 5_000_000)
                i += 1
                if i % Self.peekEveryChunks == 0 {
                    // Product speculative path
                    if !state.speculativeText.isEmpty {
                        livePeeks.append(state.speculativeText)
                    } else if let p = await state.pipeline.peekTranscription(), !p.isEmpty {
                        livePeeks.append(p)
                    }
                }
            }

            // Capture last live preview before stop
            if !state.speculativeText.isEmpty {
                livePeeks.append(state.speculativeText)
            }

            state.stopRecording()
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if case .ready = state.status { break }
            }

            let total = state.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let score = TranscriptionScoring.scoreLiveTotal(
                id: item.0,
                reference: item.1,
                livePeeks: livePeeks,
                totalHypothesis: total
            )
            print(score.summaryLine)
            results.append(score)
        }

        #expect(results.count == phrases.count)
        let ranking = TranscriptionScoring.rankLiveTotal(results)
        print(ranking.leaderboard)

        #expect(
            ranking.meanTotalMajorWER <= 0.40,
            "AppState TOTAL mean majorWER \(ranking.meanTotalMajorWER) exceeds 0.40\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(!s.totalHypothesis.isEmpty, "empty AppState total for \(s.id)")
        }
    }

    @Test("Scoring helpers: generator smoke without model")
    func generatorSmoke() throws {
        let samples = try SpeechAudioGenerator.synthesize(text: "hello", voice: "Samantha")
        #expect(samples.count > 1600)
        let s = TranscriptionScoring.scoreLiveTotal(
            id: "smoke",
            reference: "hello",
            livePeeks: ["he", "hello"],
            totalHypothesis: "hello"
        )
        #expect(s.total.wer == 0)
        #expect(s.liveHypothesis == "hello")
        #expect(s.livePeeks.count == 2)
    }
}
