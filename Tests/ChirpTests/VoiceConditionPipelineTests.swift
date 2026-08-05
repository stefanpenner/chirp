// VoiceConditionPipelineTests.swift — Realistic soft/muffled/noisy voice → pipeline
// → scored grades with regression ceilings (only improve, never silently regress).
//
// Flow per phrase × condition:
//   text → macOS `say` → VoiceCondition (soft / muffle / room noise / harsh)
//        → Transcriber stream + flush → TextPostProcessor
//        → TranscriptionScoring (WER / majorWER) + letter grade
//        → assert mean/per-phrase ceilings (tighten-only budgets)
//
// Run:
//   bazel test //:VoiceConditionPipelineTests --test_output=all
//   bazel test //:AudioCorpusPipelineTests --test_filter=VoiceCondition --test_output=all

import Testing
import Foundation
@testable import Chirp

/// Regression ceilings for acoustic conditions.
/// **Tighten when quality improves; never loosen without a tracked issue.**
enum VoiceConditionBudgets {
    /// Clean TTS control (sanity vs known clean corpus).
    static let cleanMeanMajorWER: Double = 0.12
    static let cleanMeanWER: Double = 0.18
    static let cleanMinGrade = "B" // mean major ≤ 10% is A; allow B band via ceiling

    /// Soft / far-mic (gain ~0.15).
    static let softMeanMajorWER: Double = 0.30
    static let softMeanWER: Double = 0.40
    static let softPerPhraseMajorWER: Double = 0.75

    /// Muffled (low-pass).
    static let muffledMeanMajorWER: Double = 0.35
    static let muffledMeanWER: Double = 0.45
    static let muffledPerPhraseMajorWER: Double = 0.80

    /// Soft + muffled.
    static let softMuffledMeanMajorWER: Double = 0.45
    static let softMuffledMeanWER: Double = 0.55

    /// White noise 15 dB SNR (matches existing noisy suite spirit).
    static let noisyWhiteMeanMajorWER: Double = 0.40
    static let noisyWhiteMeanWER: Double = 0.55

    /// Room/HVAC-ish pink noise ~12 dB.
    static let noisyRoomMeanMajorWER: Double = 0.45
    static let noisyRoomMeanWER: Double = 0.60

    /// Soft + muffled + room noise (harsh desk).
    static let harshDeskMeanMajorWER: Double = 0.60
    static let harshDeskMeanWER: Double = 0.75
    static let harshDeskPerPhraseMajorWER: Double = 1.0
    /// Still require some content — not total collapse on all phrases.
    static let harshDeskMinNonEmptyRate: Double = 0.50
    static let harshDeskMinMeanRecall: Double = 0.30
}

@Suite("Voice conditions (soft / muffled / noisy) graded regression", .serialized)
struct VoiceConditionPipelineTests {

    /// Shared short dictation lines — clear, multi-word, everyday.
    private static let phrases: [(id: String, text: String)] = [
        ("vc_hello", "hello world"),
        ("vc_note", "create a new note"),
        ("vc_meet", "schedule a meeting for three pm"),
        ("vc_email", "send an email to the team"),
        ("vc_report", "please send the report by friday"),
        ("vc_thanks", "thanks for your help"),
    ]

    // MARK: - Model discovery (same as AudioCorpusPipelineTests)

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
        for v in ["Samantha", "Alex", "Daniel"] {
            if (try? SpeechAudioGenerator.synthesize(text: "test", voice: v)) != nil {
                return v
            }
        }
        // System default voice name unknown — pass nil to `say`
        if (try? SpeechAudioGenerator.synthesize(text: "test", voice: nil)) != nil {
            return nil
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
            let segs = await transcriber.feedAudio(samples: Array(samples[start..<end]))
            segments.append(contentsOf: segs)
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

    private static func runCondition(
        _ condition: SpeechAudioGenerator.VoiceCondition,
        paths: ModelPaths,
        voice: String?,
        phrases: [(id: String, text: String)] = phrases
    ) async throws -> TranscriptionRanking {
        var pairs: [(id: String, reference: String, hypothesis: String)] = []
        for p in phrases {
            let speech: [Float]
            do {
                speech = try SpeechAudioGenerator.synthesize(text: p.text, voice: voice)
            } catch {
                speech = try SpeechAudioGenerator.synthesize(text: p.text, voice: nil)
            }
            let degraded = condition.apply(to: speech)
            let samples = SpeechAudioGenerator.withTrailingSilence(degraded, seconds: 0.8)
            let hyp = try await transcribe(samples: samples, paths: paths)
            let id = "\(condition.label)/\(p.id)"
            pairs.append((id: id, reference: p.text, hypothesis: hyp))
            let sc = TranscriptionScoring.score(id: id, reference: p.text, hypothesis: hyp)
            print(String(format:
                "voice[%@] hyp=\"%@\" majorWER=%.1f%% grade=%@",
                id, hyp, sc.majorWER * 100, TranscriptionScoring.grade(majorWER: sc.majorWER)))
        }
        return TranscriptionScoring.rank(pairs)
    }

    private static func assertUnderCeiling(
        ranking: TranscriptionRanking,
        label: String,
        meanMajor: Double,
        meanWER: Double,
        perPhraseMajor: Double? = nil
    ) {
        let g = TranscriptionScoring.grade(majorWER: ranking.meanMajorWER)
        print("\n========== VOICE \(label.uppercased()) GRADE=\(g) ==========")
        print(ranking.leaderboard)
        print("ceiling meanMajor=\(meanMajor) meanWER=\(meanWER)")
        print("================================================\n")

        #expect(
            TranscriptionScoring.withinBudget(actual: ranking.meanMajorWER, ceiling: meanMajor),
            "[\(label)] mean majorWER \(ranking.meanMajorWER) exceeds ceiling \(meanMajor) (grade \(g)) — regression?\n\(ranking.leaderboard)"
        )
        #expect(
            TranscriptionScoring.withinBudget(actual: ranking.meanWER, ceiling: meanWER),
            "[\(label)] mean WER \(ranking.meanWER) exceeds ceiling \(meanWER)\n\(ranking.leaderboard)"
        )
        if let per = perPhraseMajor {
            for s in ranking.scores {
                #expect(
                    s.majorWER <= per,
                    "[\(label)] \(s.id) majorWER \(s.majorWER) > \(per): \"\(s.hypothesis)\""
                )
            }
        }
    }

    // MARK: - Tests

    @Test("Clean control: graded under regression ceiling")
    func cleanControlGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .clean, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "clean",
            meanMajor: VoiceConditionBudgets.cleanMeanMajorWER,
            meanWER: VoiceConditionBudgets.cleanMeanWER
        )
    }

    @Test("Soft (quiet / far mic) speech graded under ceiling")
    func softSpeechGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .soft, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "soft",
            meanMajor: VoiceConditionBudgets.softMeanMajorWER,
            meanWER: VoiceConditionBudgets.softMeanWER,
            perPhraseMajor: VoiceConditionBudgets.softPerPhraseMajorWER
        )
    }

    @Test("Muffled speech graded under ceiling")
    func muffledSpeechGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .muffled, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "muffled",
            meanMajor: VoiceConditionBudgets.muffledMeanMajorWER,
            meanWER: VoiceConditionBudgets.muffledMeanWER,
            perPhraseMajor: VoiceConditionBudgets.muffledPerPhraseMajorWER
        )
    }

    @Test("Soft + muffled speech graded under ceiling")
    func softMuffledGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .softMuffled, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "softMuffled",
            meanMajor: VoiceConditionBudgets.softMuffledMeanMajorWER,
            meanWER: VoiceConditionBudgets.softMuffledMeanWER
        )
    }

    @Test("Noisy white 15 dB graded under ceiling")
    func noisyWhiteGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .noisyWhite15, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "noisyWhite15",
            meanMajor: VoiceConditionBudgets.noisyWhiteMeanMajorWER,
            meanWER: VoiceConditionBudgets.noisyWhiteMeanWER
        )
    }

    @Test("Noisy room/HVAC 12 dB graded under ceiling")
    func noisyRoomGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .noisyRoom12, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "noisyRoom12",
            meanMajor: VoiceConditionBudgets.noisyRoomMeanMajorWER,
            meanWER: VoiceConditionBudgets.noisyRoomMeanWER
        )
    }

    @Test("Harsh desk (soft+muffled+room) graded under ceiling")
    func harshDeskGraded() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        let ranking = try await Self.runCondition(
            .harshDesk, paths: paths, voice: Self.workingVoice()
        )
        #expect(ranking.scores.count >= 4)
        Self.assertUnderCeiling(
            ranking: ranking,
            label: "harshDesk",
            meanMajor: VoiceConditionBudgets.harshDeskMeanMajorWER,
            meanWER: VoiceConditionBudgets.harshDeskMeanWER,
            perPhraseMajor: VoiceConditionBudgets.harshDeskPerPhraseMajorWER
        )

        let nonEmpty = ranking.scores.filter { !$0.hypothesis.isEmpty }.count
        let rate = Double(nonEmpty) / Double(ranking.scores.count)
        #expect(
            rate >= VoiceConditionBudgets.harshDeskMinNonEmptyRate,
            "harsh desk non-empty rate \(rate) < \(VoiceConditionBudgets.harshDeskMinNonEmptyRate)"
        )

        let meanRecall = ranking.scores.map {
            TranscriptionScoring.tokenRecall(reference: $0.reference, hypothesis: $0.hypothesis)
        }.reduce(0, +) / Double(ranking.scores.count)
        #expect(
            meanRecall >= VoiceConditionBudgets.harshDeskMinMeanRecall,
            "harsh desk mean recall \(meanRecall) < \(VoiceConditionBudgets.harshDeskMinMeanRecall)"
        )
    }

    @Test("Master report: all conditions graded (regression dashboard)")
    func masterConditionReport() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: model not found")
            return
        }
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }

        // Subset for wall time; full suites cover each condition alone.
        let core = Array(Self.phrases.prefix(4))
        let conditions: [(SpeechAudioGenerator.VoiceCondition, Double, Double)] = [
            (.clean, VoiceConditionBudgets.cleanMeanMajorWER, VoiceConditionBudgets.cleanMeanWER),
            (.soft, VoiceConditionBudgets.softMeanMajorWER, VoiceConditionBudgets.softMeanWER),
            (.muffled, VoiceConditionBudgets.muffledMeanMajorWER, VoiceConditionBudgets.muffledMeanWER),
            (.noisyRoom12, VoiceConditionBudgets.noisyRoomMeanMajorWER, VoiceConditionBudgets.noisyRoomMeanWER),
            (.harshDesk, VoiceConditionBudgets.harshDeskMeanMajorWER, VoiceConditionBudgets.harshDeskMeanWER),
        ]

        var lines: [String] = ["========== VOICE CONDITION MASTER REPORT =========="]
        let voice = Self.workingVoice()

        for (cond, majCeil, werCeil) in conditions {
            let ranking = try await Self.runCondition(
                cond, paths: paths, voice: voice, phrases: core
            )
            let g = TranscriptionScoring.grade(majorWER: ranking.meanMajorWER)
            let ok = TranscriptionScoring.withinBudget(
                actual: ranking.meanMajorWER, ceiling: majCeil
            )
            let row = String(format:
                "%@ grade=%@ meanMajor=%.1f%% (ceil %.0f%%) meanWER=%.1f%% (ceil %.0f%%) %@",
                cond.label.padding(toLength: 14, withPad: " ", startingAt: 0),
                g,
                ranking.meanMajorWER * 100, majCeil * 100,
                ranking.meanWER * 100, werCeil * 100,
                ok ? "PASS" : "FAIL")
            lines.append(row)
            print(ranking.leaderboard)
            #expect(ok, "master: \(cond.label) regressed\n\(ranking.leaderboard)")
            #expect(
                TranscriptionScoring.withinBudget(actual: ranking.meanWER, ceiling: werCeil),
                "master: \(cond.label) WER regressed"
            )
        }
        lines.append("===================================================")
        print(lines.joined(separator: "\n"))
    }

    @Test("Budgets only tighten: clean ceiling stricter than harsh")
    func budgetOrdering() {
        // Guard against accidental ceiling inversion (would hide regressions).
        #expect(VoiceConditionBudgets.cleanMeanMajorWER
                < VoiceConditionBudgets.softMeanMajorWER)
        #expect(VoiceConditionBudgets.softMeanMajorWER
                <= VoiceConditionBudgets.softMuffledMeanMajorWER)
        #expect(VoiceConditionBudgets.noisyWhiteMeanMajorWER
                <= VoiceConditionBudgets.harshDeskMeanMajorWER)
        #expect(VoiceConditionBudgets.cleanMeanMajorWER
                < VoiceConditionBudgets.harshDeskMeanMajorWER)
    }
}
