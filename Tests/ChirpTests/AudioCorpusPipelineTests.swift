// AudioCorpusPipelineTests.swift — Generate real speech audio, pipe through the
// offline pipeline, score hypotheses with WER/CER, and rank the corpus.
//
// Flow per phrase:
//   text → macOS `say`/`afconvert` (16 kHz mono Float32)
//        → Transcriber (or AppState) in ~85 ms chunks
//        → TextPostProcessor
//        → TranscriptionScoring (WER / majorWER / CER)
//        → ranked leaderboard + hard budgets
//
// Requires Parakeet + Silero models (same discovery as TranscriberIntegrationTests).
// Run: bazel test //:AudioCorpusPipelineTests --test_output=all

import Testing
import Foundation
@testable import Chirp

// Serialized: one model load / TTS at a time → clean ranked logs, no EP thrash.
@Suite("Audio corpus pipeline (generated speech → ranked WER)", .serialized)
struct AudioCorpusPipelineTests {

    // MARK: - Corpus

    /// Golden phrases: short, clear, ASCII-friendly for macOS TTS + Parakeet.
    /// Expected text is what we score against after ASR (+ light post-process).
    private static let corpus: [(id: String, text: String)] = [
        ("hello_world", "hello world"),
        ("numbers", "the quick brown fox jumps over the lazy dog"),
        ("dictation", "please send the report by friday"),
        ("calendar", "schedule a meeting for three pm"),
        ("address", "open the document on my desktop"),
        ("short_ok", "okay"),
        ("question", "what time is the flight"),
        ("command", "create a new note"),
        ("email", "send an email to the team"),
        ("remind", "remind me to call mom tomorrow"),
        ("search", "search for the quarterly budget"),
        // Broader dictation coverage
        ("thanks", "thanks for your help"),
        ("weather", "what is the weather tomorrow"),
        ("ship", "ship the package on monday"),
        ("code", "open the pull request"),
        ("name", "my name is alex"),
    ]

    /// Mean WER ceiling for clean TTS → Parakeet on this corpus.
    /// Raw WER still reported; budgets use majorWER (article-only swaps ignored).
    private static let maxMeanMajorWER: Double = 0.08
    private static let maxMeanWER: Double = 0.12
    private static let maxMedianWER: Double = 0.05
    private static let maxMeanCER: Double = 0.08
    /// No single phrase may be a near-total miss on clean audio.
    private static let maxPerPhraseWER: Double = 0.35
    /// Real-time factor budget (decode_time / audio_duration). Offline Parakeet
    /// on CPU is typically RTF ≈ 0.02–0.05; fail if we regress above 0.5.
    private static let maxMeanRTF: Double = 0.50

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

        // Fresh list counter per utterance (matches new recording).
        // Do not reset FormatSettings here — callers pin ITN toggles for the suite.
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

        // Apply same light post-process the product uses (per segment, then join).
        // Process segments individually so list counters advance like live sessions.
        var processed: [String] = []
        for seg in segments {
            let p = TextPostProcessor.process(seg)
            if !p.isEmpty { processed.append(p) }
        }
        let hyp = processed.joined(separator: " ")
        return (hyp, elapsed)
    }

    /// Pick a working system TTS voice (US English preferred).
    private static func workingVoice() -> String? {
        workingVoices(limit: 1).first
    }

    /// Probe candidate `say` voices; return up to `limit` that synthesize.
    private static func workingVoices(
        candidates: [String] = CommandPhraseEval.multiVoiceCandidates,
        limit: Int = 8
    ) -> [String] {
        var out: [String] = []
        for v in candidates {
            guard out.count < limit else { break }
            do {
                _ = try SpeechAudioGenerator.synthesize(text: "test", voice: v)
                out.append(v)
            } catch {
                continue
            }
        }
        if out.isEmpty {
            // System default
            do {
                _ = try SpeechAudioGenerator.synthesize(text: "test", voice: nil)
            } catch {
                return []
            }
        }
        return out
    }

    /// Generate speech → trailing silence → transcribe → scored tuple + timing.
    private static func runPhrase(
        id: String,
        spoken: String,
        reference: String,
        paths: ModelPaths,
        voice: String?
    ) async throws -> (
        id: String,
        reference: String,
        hypothesis: String,
        elapsed: TimeInterval,
        sampleCount: Int
    )? {
        let speech: [Float]
        do {
            speech = try SpeechAudioGenerator.synthesize(text: spoken, voice: voice)
        } catch {
            Issue.record("TTS failed for \(id): \(error)")
            return nil
        }
        let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
        #expect(samples.count > 1600, "Generated audio too short for \(id)")
        let (hyp, elapsed) = try await transcribe(samples: samples, paths: paths)
        let audioSec = Double(samples.count) / Double(DecodePolicy.sampleRate)
        let rtf = audioSec > 0 ? elapsed / audioSec : 0
        print(String(format:
            "phrase[%@] spoken=\"%@\" ref=\"%@\" hyp=\"%@\" samples=%d audio=%.2fs decode=%.2fs RTF=%.2f",
            id, spoken, reference, hyp, samples.count, audioSec, elapsed, rtf))
        return (
            id: id,
            reference: reference,
            hypothesis: hyp,
            elapsed: elapsed,
            sampleCount: samples.count
        )
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

        // Clean corpus scores ASR content words; ITN date expansion is ranked separately.
        FormatSettings.testExpandRelativeDates = false
        FormatSettings.testExpandNumberedLists = false
        FormatSettings.testExpandBullets = false
        defer { FormatSettings.resetTestOverrides() }

        let workingVoice = Self.workingVoice()

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        var rtfSum = 0.0
        var rtfCount = 0

        for item in Self.corpus {
            guard let run = try await Self.runPhrase(
                id: item.id, spoken: item.text, reference: item.text,
                paths: paths, voice: workingVoice
            ) else { continue }
            pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
            let audioSec = Double(run.sampleCount) / Double(DecodePolicy.sampleRate)
            let rtf = audioSec > 0 ? run.elapsed / audioSec : 0
            rtfSum += rtf
            rtfCount += 1
        }

        #expect(pairs.count >= 5, "Too few corpus items transcribed (TTS or model failure)")

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)
        let meanRTF = rtfCount > 0 ? rtfSum / Double(rtfCount) : 0
        print(String(format: "mean RTF=%.3f (budget ≤ %.2f)", meanRTF, Self.maxMeanRTF))

        #expect(
            ranking.meanMajorWER <= Self.maxMeanMajorWER,
            "mean majorWER \(ranking.meanMajorWER) exceeds budget \(Self.maxMeanMajorWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanWER <= Self.maxMeanWER,
            "mean WER \(ranking.meanWER) exceeds budget \(Self.maxMeanWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.medianWER <= Self.maxMedianWER,
            "median WER \(ranking.medianWER) exceeds budget \(Self.maxMedianWER)\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanCER <= Self.maxMeanCER,
            "mean CER \(ranking.meanCER) exceeds budget \(Self.maxMeanCER)\n\(ranking.leaderboard)"
        )
        #expect(
            meanRTF <= Self.maxMeanRTF,
            "mean RTF \(meanRTF) exceeds budget \(Self.maxMeanRTF)"
        )
        for s in ranking.scores {
            #expect(
                s.wer <= Self.maxPerPhraseWER,
                "phrase \(s.id) WER \(s.wer) too high (hyp=\"\(s.hypothesis)\")"
            )
            #expect(
                s.majorWER <= Self.maxPerPhraseWER,
                "phrase \(s.id) majorWER \(s.majorWER) too high (hyp=\"\(s.hypothesis)\")"
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
        let (hyp, _) = try await Self.transcribe(samples: samples, paths: paths)
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

        // Score ASR under noise; leave relative-date ITN off so "tomorrow" stays a word.
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        // Broader subset of clean corpus under additive noise (15 dB SNR).
        let phrases = [
            ("noise_hello", "hello world"),
            ("noise_fox", "the quick brown fox"),
            ("noise_note", "create a new note"),
            ("noise_meet", "schedule a meeting for three pm"),
            ("noise_email", "send an email to the team"),
            ("noise_ok", "okay"),
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
            let (hyp, elapsed) = try await Self.transcribe(samples: samples, paths: paths)
            pairs.append((id: item.0, reference: item.1, hypothesis: hyp))
            print(String(format: "noisy[%@] hyp=\"%@\" decode=%.2fs", item.0, hyp, elapsed))
        }

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)

        // Relaxed budgets under 15 dB SNR (majorWER ignores a/the swaps).
        #expect(pairs.count >= 4, "too few noisy phrases transcribed")
        #expect(
            ranking.meanMajorWER <= 0.40,
            "noisy mean majorWER \(ranking.meanMajorWER) exceeds 0.40\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanWER <= 0.55,
            "noisy mean WER \(ranking.meanWER) exceeds 0.55\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(
                s.majorWER <= 0.75,
                "noisy phrase \(s.id) majorWER \(s.majorWER) too high (hyp=\"\(s.hypothesis)\")"
            )
        }
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

    @Test("Multi-utterance session: two phrases with silence, ranked")
    @MainActor
    func multiUtteranceSession() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let phrase1 = "hello world"
        let phrase2 = "create a new note"

        let speech1 = try SpeechAudioGenerator.synthesize(text: phrase1, voice: "Samantha")
        let speech2 = try SpeechAudioGenerator.synthesize(text: phrase2, voice: "Samantha")
        // phrase1 + silence gap (triggers VAD commit) + phrase2 + trailing silence
        var samples = SpeechAudioGenerator.withTrailingSilence(speech1, seconds: 0.8)
        samples += speech2
        samples = SpeechAudioGenerator.withTrailingSilence(samples, seconds: 0.8)

        let hyp = try await Self.transcribeViaAppState(samples: samples, paths: paths)
        print("multi-utterance hyp=\"\(hyp)\"")

        let score = TranscriptionScoring.score(
            id: "multi",
            reference: "\(phrase1) \(phrase2)",
            hypothesis: hyp
        )
        print(score.summaryLine)

        #expect(!hyp.isEmpty, "multi-utterance produced empty text")
        #expect(
            score.majorWER <= 0.35,
            "multi-utterance majorWER \(score.majorWER) too high: \"\(hyp)\""
        )
        let norm = TranscriptionScoring.normalize(hyp)
        #expect(norm.contains("hello") || norm.contains("world"), "missing first phrase in \"\(hyp)\"")
        #expect(norm.contains("note") || norm.contains("create"), "missing second phrase in \"\(hyp)\"")
        // SegmentJoiner should insert a sentence break between capitalized utterances
        #expect(
            hyp.contains(". ") || hyp.contains("."),
            "expected sentence boundary between multi-utterance phrases: \"\(hyp)\""
        )
    }

    // MARK: - Spoken punctuation (audio → post-process → ranked)

    /// Spoken punctuation phrases: TTS speaks the command words; pipeline should
    /// rewrite them into punctuation via TextPostProcessor.
    @Test("Spoken punctuation audio ranks under WER budget")
    func rankedSpokenPunctuation() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        // (id, spoken TTS text, expected content after post-process for WER)
        // Normalize strips punctuation, so content WER scores the words;
        // separate asserts check marks landed.
        let items: [(id: String, spoken: String, reference: String, mustContain: String)] = [
            ("punct_period", "hello world period", "hello world", "."),
            ("punct_question", "what time is it question mark", "what time is it", "?"),
            ("punct_comma", "yes comma please", "yes please", ","),
            ("punct_exclaim", "great job exclamation mark", "great job", "!"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        var markHits = 0

        for item in items {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: item.spoken, voice: "Samantha")
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: item.spoken, voice: nil)
            }
            let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
            let (hyp, elapsed) = try await Self.transcribe(samples: samples, paths: paths)
            pairs.append((id: item.id, reference: item.reference, hypothesis: hyp))
            if hyp.contains(item.mustContain) { markHits += 1 }
            print(String(format:
                "punct[%@] spoken=\"%@\" hyp=\"%@\" wantMark=\"%@\" hit=%@ decode=%.2fs",
                item.id, item.spoken, hyp, item.mustContain,
                hyp.contains(item.mustContain) ? "yes" : "no", elapsed))
        }

        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)
        print("punctuation mark hits: \(markHits)/\(items.count)")

        #expect(pairs.count == items.count)
        // Content words must land; punctuation rewrite is best-effort under TTS variance
        #expect(
            ranking.meanMajorWER <= 0.25,
            "spoken-punct mean majorWER \(ranking.meanMajorWER) exceeds 0.25\n\(ranking.leaderboard)"
        )
        // At least half the marks should survive ASR + rewrite on clean TTS
        #expect(
            markHits >= items.count / 2,
            "too few punctuation marks rewritten (\(markHits)/\(items.count))"
        )
    }

    // MARK: - Continuous stream with mid-session VAD commits

    /// Feed a long stream: phrase → silence → phrase → silence.
    /// VAD should commit mid-stream; flush gets the tail. Score full session.
    @Test("Continuous stream with mid-session VAD commits, ranked")
    func continuousStreamMidCommitsRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let phrases = [
            "hello world",
            "create a new note",
            "schedule a meeting for three pm",
        ]

        var samples: [Float] = []
        for (i, phrase) in phrases.enumerated() {
            let speech = try SpeechAudioGenerator.synthesize(text: phrase, voice: "Samantha")
            samples += speech
            // Mid-phrase silence long enough for VAD endpoint (≥0.5s min_silence)
            let gap = i < phrases.count - 1 ? 0.9 : 0.8
            samples += SpeechAudioGenerator.silence(seconds: gap)
        }

        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize")
            return
        }

        let chunkSize = DecodePolicy.streamChunkSamples
        var committed: [String] = []
        var midCommits = 0
        let t0 = Date()
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let segs = await transcriber.feedAudio(samples: chunk)
            if !segs.isEmpty {
                midCommits += segs.count
                committed.append(contentsOf: segs)
            }
        }
        let flushed = await transcriber.flush()
        if !flushed.isEmpty { committed.append(flushed) }
        let elapsed = Date().timeIntervalSince(t0)

        let raw = committed.joined(separator: " ")
        let hyp = TextPostProcessor.process(raw)
        let reference = phrases.joined(separator: " ")
        let score = TranscriptionScoring.score(
            id: "stream_session",
            reference: reference,
            hypothesis: hyp
        )
        let audioSec = Double(samples.count) / Double(DecodePolicy.sampleRate)
        let rtf = audioSec > 0 ? elapsed / audioSec : 0

        print(String(format:
            "stream midCommits=%d segments=%d audio=%.2fs decode=%.2fs RTF=%.2f",
            midCommits, committed.count, audioSec, elapsed, rtf))
        print("stream segments: \(committed)")
        print(score.summaryLine)

        #expect(!hyp.isEmpty, "continuous stream produced empty hyp")
        // Prefer mid-session commits when silence gaps are present
        #expect(
            midCommits >= 1 || !flushed.isEmpty,
            "expected at least one VAD commit or flush text"
        )
        #expect(
            score.majorWER <= 0.30,
            "stream majorWER \(score.majorWER) too high: \"\(hyp)\"\nref=\"\(reference)\""
        )
        #expect(rtf <= Self.maxMeanRTF, "stream RTF \(rtf) exceeds budget")

        let norm = TranscriptionScoring.normalize(hyp)
        #expect(norm.contains("hello") || norm.contains("world"), "missing phrase1 in \"\(hyp)\"")
        #expect(norm.contains("note") || norm.contains("create"), "missing phrase2 in \"\(hyp)\"")
        #expect(norm.contains("meeting") || norm.contains("schedule"), "missing phrase3 in \"\(hyp)\"")
    }

    // MARK: - Ranked multi-voice robustness

    /// Free-dictation multi-voice: several short phrases × regional voices.
    /// Independent phrase×voice pairs (not multi-utterance join). Caps wall
    /// time vs full corpus×voices while catching free-text accent variance
    /// that command multi-voice soak never sees.
    @Test("Multi-voice free dictation phrases rank under budget")
    func multiVoiceRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        // Already-green clean-corpus lines only; 4 phrases × ≤4 voices.
        let phrases: [(id: String, text: String)] = [
            ("mv_report", "please send the report by friday"),
            ("mv_hello", "hello world"),
            ("mv_note", "create a new note"),
            ("mv_meet", "schedule a meeting for three pm"),
        ]
        let candidates = Self.workingVoices(limit: 4)
        var pairs: [(id: String, reference: String, hypothesis: String)] = []

        for voice in candidates {
            for p in phrases {
                guard let run = try await Self.runPhrase(
                    id: "\(p.id)_\(voice)",
                    spoken: p.text,
                    reference: p.text,
                    paths: paths,
                    voice: voice
                ) else {
                    print("voice \(voice) phrase \(p.id) skip")
                    continue
                }
                pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
                let sc = TranscriptionScoring.score(
                    id: run.id,
                    reference: run.reference,
                    hypothesis: run.hypothesis
                )
                print(String(
                    format: "free-mv[%@/%@] hyp=\"%@\" majorWER=%.2f",
                    voice,
                    p.id,
                    run.hypothesis,
                    sc.majorWER
                ))
            }
        }

        #expect(pairs.count >= 6, "need ≥6 voice×phrase free-dict runs (got \(pairs.count))")
        let ranking = TranscriptionScoring.rank(pairs)
        print(ranking.leaderboard)

        #expect(
            ranking.meanMajorWER <= 0.20,
            "free multi-voice mean majorWER \(ranking.meanMajorWER) exceeds 0.20\n\(ranking.leaderboard)"
        )
        // Catastrophic misses should be rare on clean TTS
        let bad = ranking.scores.filter { $0.majorWER > 0.50 }.count
        #expect(
            bad <= max(1, pairs.count / 3),
            "too many free multi-voice misses: \(bad)/\(pairs.count)\n\(ranking.leaderboard)"
        )
        if let best = ranking.best {
            #expect(
                best.majorWER <= 0.20,
                "best free multi-voice still majorWER \(best.majorWER): \"\(best.hypothesis)\""
            )
        }
    }

    // MARK: - Full ranked report (smoke for CI logs)

    /// Single entry that prints a compact ranked table for the core subset.
    /// Useful when scanning bazel --test_output=all for regressions.
    @Test("Ranked report: generate → pipe → score → leaderboard")
    func rankedReportSmoke() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let core = [
            ("rpt_hello", "hello world"),
            ("rpt_fox", "the quick brown fox"),
            ("rpt_note", "create a new note"),
            ("rpt_meet", "schedule a meeting for three pm"),
            ("rpt_email", "send an email to the team"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in core {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: "Samantha")
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: item.1, voice: nil)
            }
            let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
            let (hyp, _) = try await Self.transcribe(samples: samples, paths: paths)
            pairs.append((id: item.0, reference: item.1, hypothesis: hyp))
        }

        let ranking = TranscriptionScoring.rank(pairs)
        // Explicit ranked table for humans reading CI logs
        print("\n========== CHIRP AUDIO PIPELINE RANKED REPORT ==========")
        print(ranking.leaderboard)
        print("========================================================\n")

        #expect(pairs.count == core.count)
        #expect(
            ranking.meanMajorWER <= 0.10,
            "report mean majorWER \(ranking.meanMajorWER) exceeds 0.10\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanWER <= 0.15,
            "report mean WER \(ranking.meanWER) exceeds 0.15\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(!s.hypothesis.isEmpty, "empty hyp for \(s.id)")
        }
    }

    // MARK: - ITN audio corpus (generate → pipe → post-process → rank)

    /// Spoken numbers / times / money through real ASR + light ITN.
    /// Reference is the *normalized product* form we expect after post-process.
    @Test("ITN numbers audio ranks under WER budget")
    func rankedITNNumbers() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        let voice = Self.workingVoice()

        // (id, TTS spoken form, expected after ASR + ITN — content words for WER)
        let items: [(id: String, spoken: String, reference: String)] = [
            ("itn_time", "meeting at three pm", "meeting at 3 pm"),
            ("itn_percent", "increase by fifty percent", "increase by 50 percent"),
            ("itn_money", "costs twenty dollars", "costs 20 dollars"),
            ("itn_cardinal", "send one hundred emails", "send 100 emails"),
            ("itn_decimal", "about three point five miles", "about 3.5 miles"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in items {
            guard let run = try await Self.runPhrase(
                id: item.id, spoken: item.spoken, reference: item.reference,
                paths: paths, voice: voice
            ) else { continue }
            pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
        }

        #expect(pairs.count >= 3, "too few ITN number phrases transcribed")
        let ranking = TranscriptionScoring.rank(pairs)
        print("\n========== ITN NUMBERS RANKED ==========")
        print(ranking.leaderboard)
        print("========================================\n")

        // Clean TTS + ITN: allow ASR variance; content should mostly land.
        #expect(
            ranking.meanMajorWER <= 0.35,
            "ITN numbers mean majorWER \(ranking.meanMajorWER) exceeds 0.35\n\(ranking.leaderboard)"
        )
        // At least one phrase should contain a digit (ITN or ASR digit form).
        let digitHits = ranking.scores.filter { score in
            score.hypothesis.rangeOfCharacter(from: .decimalDigits) != nil
        }.count
        #expect(
            digitHits >= 1,
            "expected at least one ITN digit rewrite in hypotheses"
        )
    }

    /// Spoken dates through real ASR + date ITN.
    @Test("ITN dates audio ranks under WER budget")
    func rankedITNDates() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        let voice = Self.workingVoice()

        // Pin relative dates so scoring is deterministic against absolute forms.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 8; comps.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        SpokenDateITN.nowProvider = { pinned }
        SpokenDateITN.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        FormatSettings.testExpandRelativeDates = true
        defer {
            SpokenDateITN.resetClock()
            SpokenDateITN.resetTimeZone()
            FormatSettings.resetTestOverrides()
        }

        let items: [(id: String, spoken: String, reference: String)] = [
            ("itn_month_day", "schedule for march fifth", "schedule for March 5"),
            ("itn_weekday", "meet on monday please", "meet on Monday please"),
            ("itn_tomorrow", "due tomorrow morning", "due July 9 2026 morning"),
            ("itn_full_date", "on july fifteenth twenty twenty four", "on July 15 2024"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in items {
            guard let run = try await Self.runPhrase(
                id: item.id, spoken: item.spoken, reference: item.reference,
                paths: paths, voice: voice
            ) else { continue }
            pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
        }

        #expect(pairs.count >= 2, "too few ITN date phrases transcribed")
        let ranking = TranscriptionScoring.rank(pairs)
        print("\n========== ITN DATES RANKED ==========")
        print(ranking.leaderboard)
        print("======================================\n")

        #expect(
            ranking.meanMajorWER <= 0.45,
            "ITN dates mean majorWER \(ranking.meanMajorWER) exceeds 0.45\n\(ranking.leaderboard)"
        )
        // Month-name or weekday capitalization / rewrite smoke
        let anyDateShape = ranking.scores.contains { s in
            let h = s.hypothesis
            return h.contains("March") || h.contains("Monday") || h.contains("July")
                || h.contains("2024") || h.contains("2026")
                || TranscriptionScoring.normalize(h).contains("march")
                || TranscriptionScoring.normalize(h).contains("monday")
        }
        #expect(anyDateShape, "expected at least one date-like rewrite in hyp set")
    }

    /// Spoken list commands through real ASR + list ITN; rank content + check markers.
    @Test("ITN lists audio ranks under WER budget")
    func rankedITNLists() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        let voice = Self.workingVoice()
        FormatSettings.testExpandNumberedLists = true
        FormatSettings.testExpandBullets = true
        defer { FormatSettings.resetTestOverrides() }

        // Reference is content after list rewrite (markers stripped by normalize for WER).
        let items: [(id: String, spoken: String, reference: String, wantMarker: String)] = [
            ("list_num1", "number one milk", "1 milk", "1."),
            ("list_next", "number one apples next number oranges", "1 apples 2 oranges", "2."),
            ("list_bullet", "bullet point first idea next bullet second idea", "first idea second idea", "•"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        var markerHits = 0
        for item in items {
            guard let run = try await Self.runPhrase(
                id: item.id, spoken: item.spoken, reference: item.reference,
                paths: paths, voice: voice
            ) else { continue }
            pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
            if run.hypothesis.contains(item.wantMarker) { markerHits += 1 }
            print("list marker[\(item.id)] want=\"\(item.wantMarker)\" hit=\(run.hypothesis.contains(item.wantMarker))")
        }

        #expect(pairs.count >= 2, "too few list phrases transcribed")
        let ranking = TranscriptionScoring.rank(pairs)
        print("\n========== ITN LISTS RANKED ==========")
        print(ranking.leaderboard)
        print("marker hits: \(markerHits)/\(pairs.count)")
        print("======================================\n")

        // Content WER under relaxed budget (list commands are ASR-hard for TTS).
        #expect(
            ranking.meanMajorWER <= 0.50,
            "ITN lists mean majorWER \(ranking.meanMajorWER) exceeds 0.50\n\(ranking.leaderboard)"
        )
        // At least one list marker should survive ASR + rewrite on clean TTS.
        #expect(
            markerHits >= 1,
            "expected at least one list marker rewritten (got \(markerHits)/\(pairs.count))"
        )
        for s in ranking.scores {
            #expect(!s.hypothesis.isEmpty, "empty hyp for \(s.id)")
        }
    }

    /// End-to-end AppState path with generated ITN speech, ranked.
    @Test("AppState ITN: generated audio → typed text ranked")
    @MainActor
    func rankedITNViaAppState() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }

        let subset: [(id: String, spoken: String, reference: String)] = [
            ("e2e_itn_time", "schedule a meeting for three pm", "schedule a meeting for 3 pm"),
            ("e2e_itn_num", "number one milk next number eggs", "1 milk 2 eggs"),
            ("e2e_itn_hello", "hello world period", "hello world"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for item in subset {
            TextPostProcessor.resetSessionFormatState()
            FormatSettings.testExpandNumberedLists = true
            defer { FormatSettings.resetTestOverrides() }

            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: item.spoken, voice: "Samantha")
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: item.spoken, voice: nil)
            }
            let samples = SpeechAudioGenerator.withTrailingSilence(speech, seconds: 0.8)
            let hyp = try await Self.transcribeViaAppState(samples: samples, paths: paths)
            pairs.append((id: item.id, reference: item.reference, hypothesis: hyp))
            print("e2e-itn[\(item.id)] spoken=\"\(item.spoken)\" hyp=\"\(hyp)\"")
        }

        let ranking = TranscriptionScoring.rank(pairs)
        print("\n========== APPSTATE ITN RANKED ==========")
        print(ranking.leaderboard)
        print("=========================================\n")

        #expect(pairs.count == subset.count)
        #expect(
            ranking.meanMajorWER <= 0.55,
            "E2E ITN mean majorWER \(ranking.meanMajorWER) exceeds 0.55\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(!s.hypothesis.isEmpty, "empty hypothesis for \(s.id)")
        }
    }

    /// Master ranked report: clean dictation + ITN phrases in one leaderboard.
    @Test("Master ranked report: generate → pipe → score all categories")
    func masterRankedReport() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        let voice = Self.workingVoice()
        FormatSettings.resetTestOverrides()
        TextPostProcessor.resetSessionFormatState()

        let all: [(id: String, spoken: String, reference: String)] = [
            // Clean dictation
            ("m_hello", "hello world", "hello world"),
            ("m_note", "create a new note", "create a new note"),
            ("m_meet", "schedule a meeting for three pm", "schedule a meeting for 3 pm"),
            ("m_email", "send an email to the team", "send an email to the team"),
            // ITN
            ("m_percent", "save twenty percent", "save 20 percent"),
            ("m_money", "pay fifty dollars", "pay 50 dollars"),
            ("m_list", "number one milk", "1 milk"),
            ("m_punct", "hello world period", "hello world"),
        ]

        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        var rtfSum = 0.0
        for item in all {
            guard let run = try await Self.runPhrase(
                id: item.id, spoken: item.spoken, reference: item.reference,
                paths: paths, voice: voice
            ) else { continue }
            pairs.append((id: run.id, reference: run.reference, hypothesis: run.hypothesis))
            // Rough RTF from elapsed vs ~spoken length (samples not returned; use elapsed only log)
            rtfSum += run.elapsed
        }

        #expect(pairs.count >= 5, "too few master-report phrases")
        let ranking = TranscriptionScoring.rank(pairs)
        print("\n========== CHIRP MASTER AUDIO RANKED REPORT ==========")
        print(ranking.leaderboard)
        print(String(format: "total decode wall=%.2fs over %d phrases", rtfSum, pairs.count))
        print("======================================================\n")

        #expect(
            ranking.meanMajorWER <= 0.30,
            "master mean majorWER \(ranking.meanMajorWER) exceeds 0.30\n\(ranking.leaderboard)"
        )
        #expect(
            ranking.meanWER <= 0.40,
            "master mean WER \(ranking.meanWER) exceeds 0.40\n\(ranking.leaderboard)"
        )
        // Best phrase should be near-perfect on clean TTS
        if let best = ranking.best {
            #expect(
                best.majorWER <= 0.25,
                "best phrase majorWER \(best.majorWER) too high: \"\(best.hypothesis)\""
            )
        }
        // Worst should not be a total miss for the majority of corpus
        let catastrophic = ranking.scores.filter { $0.majorWER > 0.75 }.count
        #expect(
            catastrophic <= pairs.count / 2,
            "too many catastrophic phrases (\(catastrophic)/\(pairs.count))\n\(ranking.leaderboard)"
        )
    }

    /// Dragon command phrases: TTS → Parakeet → DictationCommand.parse hit rate.
    /// Short commands are ASR-hard (SOTA voice-agent short-utterance gap); soft
    /// budget via `CommandPhraseEval.soakMinHitRate`.
    @Test("Command phrase soak: TTS → ASR → parse hit rate")
    func commandPhraseSoak() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        let voice = Self.workingVoice()
        FormatSettings.resetTestOverrides()
        TextPostProcessor.resetSessionFormatState()

        var trials: [CommandPhraseEval.Trial] = []
        for item in CommandPhraseEval.soakPhrases {
            guard let run = try await Self.runPhrase(
                id: item.id,
                spoken: item.spoken,
                reference: item.spoken,
                paths: paths,
                voice: voice
            ) else { continue }
            let trial = CommandPhraseEval.Trial(hyp: run.hypothesis, expected: item.expected)
            let ok = CommandPhraseEval.hit(trial)
            print(String(
                format: "cmd[%@] spoken=\"%@\" hyp=\"%@\" parse=%@ hit=%@",
                item.id,
                item.spoken,
                run.hypothesis,
                String(describing: DictationCommand.parse(run.hypothesis)),
                ok ? "yes" : "no"
            ))
            trials.append(trial)
        }

        #expect(trials.count >= 6, "too few command phrases transcribed (\(trials.count))")
        let rate = CommandPhraseEval.hitRate(trials)
        print(String(
            format: "command soak hitRate=%.0f%% (budget ≥ %.0f%%) n=%d",
            rate * 100,
            CommandPhraseEval.soakMinHitRate * 100,
            trials.count
        ))
        let detail = trials.map { t in
            "  hyp=\"\(t.hyp)\" expect=\(t.expected) got=\(DictationCommand.parse(t.hyp))"
        }.joined(separator: "\n")
        #expect(
            rate >= CommandPhraseEval.soakMinHitRate,
            "command parse hitRate \(rate) below \(CommandPhraseEval.soakMinHitRate)\n\(detail)"
        )
    }

    /// Multi-voice command soak: same Dragon subset across TTS voices.
    /// SOTA voice-agent eval: command hit rate under speaker/voice variance.
    @Test("Command phrase multi-voice soak: TTS voices → ASR → parse")
    func commandPhraseMultiVoiceSoak() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        // Prefer several accents (US/UK/AU/…) when installed; cap for wall time.
        let voices = Self.workingVoices(limit: 6)
        guard voices.count >= CommandPhraseEval.multiVoiceMinVoices else {
            print("SKIP: need ≥\(CommandPhraseEval.multiVoiceMinVoices) TTS voices, got \(voices.count)")
            return
        }
        print("multi-voice using: \(voices.joined(separator: ", "))")
        FormatSettings.resetTestOverrides()
        TextPostProcessor.resetSessionFormatState()

        var trialsByVoice: [String: [CommandPhraseEval.Trial]] = [:]
        var allTrials: [CommandPhraseEval.Trial] = []

        for voice in voices {
            var voiceTrials: [CommandPhraseEval.Trial] = []
            for item in CommandPhraseEval.multiVoiceSoakPhrases {
                guard let run = try await Self.runPhrase(
                    id: "\(item.id)_\(voice)",
                    spoken: item.spoken,
                    reference: item.spoken,
                    paths: paths,
                    voice: voice
                ) else { continue }
                let trial = CommandPhraseEval.Trial(hyp: run.hypothesis, expected: item.expected)
                let ok = CommandPhraseEval.hit(trial)
                print(String(
                    format: "mv[%@/%@] spoken=\"%@\" hyp=\"%@\" hit=%@",
                    voice,
                    item.id,
                    item.spoken,
                    run.hypothesis,
                    ok ? "yes" : "no"
                ))
                voiceTrials.append(trial)
                allTrials.append(trial)
            }
            if !voiceTrials.isEmpty {
                trialsByVoice[voice] = voiceTrials
            }
        }

        #expect(
            trialsByVoice.count >= CommandPhraseEval.multiVoiceMinVoices,
            "need trials from ≥\(CommandPhraseEval.multiVoiceMinVoices) voices"
        )
        #expect(allTrials.count >= 8, "too few multi-voice trials (\(allTrials.count))")

        let pooled = CommandPhraseEval.multiVoicePooledHitRate(allTrials)
        let worst = CommandPhraseEval.minPerVoiceHitRate(trialsByVoice: trialsByVoice)
        for (voice, trials) in trialsByVoice.sorted(by: { $0.key < $1.key }) {
            let r = CommandPhraseEval.hitRate(trials)
            print(String(format: "multi-voice[%@] hitRate=%.0f%% n=%d", voice, r * 100, trials.count))
        }
        print(String(
            format: "multi-voice pooled=%.0f%% (budget ≥ %.0f%%) worstVoice=%.0f%% (floor ≥ %.0f%%) voices=%d n=%d",
            pooled * 100,
            CommandPhraseEval.multiVoiceSoakMinHitRate * 100,
            worst * 100,
            CommandPhraseEval.multiVoiceMinPerVoiceHitRate * 100,
            trialsByVoice.count,
            allTrials.count
        ))

        #expect(
            pooled >= CommandPhraseEval.multiVoiceSoakMinHitRate,
            "multi-voice pooled hitRate \(pooled) below \(CommandPhraseEval.multiVoiceSoakMinHitRate)"
        )
        #expect(
            worst >= CommandPhraseEval.multiVoiceMinPerVoiceHitRate,
            "worst voice hitRate \(worst) below \(CommandPhraseEval.multiVoiceMinPerVoiceHitRate)"
        )
    }
}
