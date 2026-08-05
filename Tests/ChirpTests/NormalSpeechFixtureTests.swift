// NormalSpeechFixtureTests.swift — Real human speech WAVs → pipeline → scored WER.
//
// Fixtures: LibriSpeech (CC BY 4.0) + LDC93S1 under Tests/ChirpTests/fixtures/.
// Covers normal speaking level and a soft (attenuated) pass so quiet-mic
// regressions fail the build.
//
// Run:
//   bazel test //:NormalSpeechFixtureTests --test_output=all
//   bazel test //:FixtureASRTests --test_output=errors   # includes short subset if wired

import Testing
import Foundation
@testable import Chirp

@Suite("Normal speech fixtures (LibriSpeech + LDC93S1)", .serialized)
struct NormalSpeechFixtureTests {

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

    private static func transcribe(samples: [Float], paths: ModelPaths) async throws -> String {
        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        guard ok else {
            Issue.record("Transcriber failed to initialize")
            return ""
        }
        FormatSettings.testExpandRelativeDates = false
        TextPostProcessor.resetSessionFormatState()

        let chunkSize = DecodePolicy.streamChunkSamples
        var segments: [String] = []
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            // Match capture path: soft AGC on each chunk (quiet / far mic).
            let chunk = DecodePolicy.softInputGain(Array(samples[start..<end]))
            segments.append(contentsOf: await transcriber.feedAudio(samples: chunk))
        }
        let flushed = await transcriber.flush()
        if !flushed.isEmpty { segments.append(flushed) }

        var processed: [String] = []
        for seg in segments {
            let p = TextPostProcessor.process(seg)
            if !p.isEmpty { processed.append(p) }
        }
        return processed.joined(separator: " ")
    }

    private static func runCorpus(
        fixtures: [SpeechFixture],
        paths: ModelPaths,
        softenGain: Float? = nil,
        idPrefix: String
    ) async throws -> TranscriptionRanking {
        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for fix in fixtures {
            guard let path = fix.resolvePath() else {
                Issue.record("Missing fixture \(fix.fileName)")
                continue
            }
            var samples = try SpeechAudioGenerator.loadWAV(path: path)
            if let g = softenGain {
                samples = SpeechAudioGenerator.soften(samples, gain: g)
            }
            samples = SpeechAudioGenerator.withTrailingSilence(samples, seconds: 0.6)
            let hyp = try await transcribe(samples: samples, paths: paths)
            let id = "\(idPrefix)/\(fix.id)"
            pairs.append((id: id, reference: fix.reference, hypothesis: hyp))
            let sc = TranscriptionScoring.score(id: id, reference: fix.reference, hypothesis: hyp)
            print(String(format:
                "fixture[%@] grade=%@ majorWER=%.1f%% hyp=\"%@\" ref=\"%@\"",
                id,
                TranscriptionScoring.grade(majorWER: sc.majorWER),
                sc.majorWER * 100,
                hyp,
                fix.reference
            ))
        }
        return TranscriptionScoring.rank(pairs)
    }

    // MARK: - Tests

    @Test("Fixtures resolve on disk")
    func fixturesPresent() {
        var found = 0
        for fix in SpeechFixtures.normalSpeech {
            if fix.resolvePath() != nil { found += 1 }
            else { print("MISSING \(fix.fileName)") }
        }
        #expect(found >= 4, "need ≥4 real-speech fixtures (got \(found))")
    }

    @Test("Normal speaking level: ranked under regression ceiling")
    func normalSpeakingLevelRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCorpus(
            fixtures: SpeechFixtures.normalSpeech,
            paths: paths,
            softenGain: nil,
            idPrefix: "normal"
        )
        #expect(ranking.scores.count >= 4)
        let g = TranscriptionScoring.grade(majorWER: ranking.meanMajorWER)
        print("\n========== NORMAL SPEECH FIXTURES grade=\(g) ==========")
        print(ranking.leaderboard)
        print("======================================================\n")

        #expect(
            TranscriptionScoring.withinBudget(
                actual: ranking.meanMajorWER,
                ceiling: SpeechFixtures.Budgets.normalMeanMajorWER
            ),
            "normal mean majorWER \(ranking.meanMajorWER) exceeds ceiling — regression?\n\(ranking.leaderboard)"
        )
        #expect(
            TranscriptionScoring.withinBudget(
                actual: ranking.meanWER,
                ceiling: SpeechFixtures.Budgets.normalMeanWER
            ),
            "normal mean WER \(ranking.meanWER) exceeds ceiling\n\(ranking.leaderboard)"
        )
        for s in ranking.scores {
            #expect(
                !s.hypothesis.isEmpty,
                "empty hyp for \(s.id)"
            )
            #expect(
                s.majorWER <= SpeechFixtures.Budgets.normalPerPhraseMajorWER,
                "\(s.id) majorWER \(s.majorWER): \"\(s.hypothesis)\""
            )
        }
    }

    @Test("Softened real speech (gain 0.15): still scores under soft ceiling")
    func softRealSpeechRanked() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        // Core set only (shorter) — soft long poetry is ASR-hard.
        let ranking = try await Self.runCorpus(
            fixtures: SpeechFixtures.normalSpeechCore,
            paths: paths,
            softenGain: 0.15,
            idPrefix: "soft"
        )
        #expect(ranking.scores.count >= 3)
        let g = TranscriptionScoring.grade(majorWER: ranking.meanMajorWER)
        print("\n========== SOFT REAL SPEECH grade=\(g) ==========")
        print(ranking.leaderboard)
        print("===============================================\n")

        let nonEmpty = ranking.scores.filter { !$0.hypothesis.isEmpty }.count
        let rate = Double(nonEmpty) / Double(max(ranking.scores.count, 1))
        #expect(
            rate >= SpeechFixtures.Budgets.softMinNonEmptyRate,
            "soft non-empty rate \(rate) < \(SpeechFixtures.Budgets.softMinNonEmptyRate)"
        )
        #expect(
            TranscriptionScoring.withinBudget(
                actual: ranking.meanMajorWER,
                ceiling: SpeechFixtures.Budgets.softMeanMajorWER
            ),
            "soft mean majorWER \(ranking.meanMajorWER) exceeds ceiling\n\(ranking.leaderboard)"
        )
        #expect(
            TranscriptionScoring.withinBudget(
                actual: ranking.meanWER,
                ceiling: SpeechFixtures.Budgets.softMeanWER
            ),
            "soft mean WER \(ranking.meanWER) exceeds ceiling\n\(ranking.leaderboard)"
        )
    }

    @Test("LDC93S1 classic smoke: expected content words")
    func ldc93s1ContentWords() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        guard let fix = SpeechFixtures.normalSpeech.first(where: { $0.id == "ldc93s1" }),
              let path = fix.resolvePath() else {
            print("SKIP: ldc93s1 missing")
            return
        }
        let samples = SpeechAudioGenerator.withTrailingSilence(
            try SpeechAudioGenerator.loadWAV(path: path),
            seconds: 0.5
        )
        let hyp = try await Self.transcribe(samples: samples, paths: paths)
        let score = TranscriptionScoring.score(
            id: "ldc93s1",
            reference: fix.reference,
            hypothesis: hyp
        )
        print(score.summaryLine)
        let n = TranscriptionScoring.normalize(hyp)
        #expect(n.contains("dark") || n.contains("suit") || n.contains("water") || n.contains("year"),
                "missing expected content words: \"\(hyp)\"")
        #expect(score.majorWER <= 0.40, "ldc93s1 majorWER \(score.majorWER): \"\(hyp)\"")
    }
}
