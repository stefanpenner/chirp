// SpeechFixtures.swift — Catalog of real human speech WAVs for ASR scoring.
// Sources: LibriSpeech (CC BY 4.0) + LDC93S1 smoke utterance. See fixtures/LICENSE.txt.

import Foundation

/// One committed real-speech clip with a ground-truth transcript.
struct SpeechFixture: Sendable {
    /// File name under Tests/ChirpTests/fixtures/ (or Tests/ChirpTests/ for legacy).
    let fileName: String
    /// Human-readable id for leaderboards.
    let id: String
    /// Reference transcript (as-spoken content; casing ignored by scorer).
    let reference: String
    /// Optional notes (source id).
    let source: String

    /// Resolve on-disk path (Bazel runfiles / source tree).
    func resolvePath(filePath: String = #filePath) -> String? {
        let base = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let candidates = [
            base.appendingPathComponent("fixtures/\(fileName)").path,
            base.appendingPathComponent(fileName).path,
            "Tests/ChirpTests/fixtures/\(fileName)",
            "Tests/ChirpTests/\(fileName)",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

enum SpeechFixtures {
    /// Normal conversational/read speech at natural levels (not TTS).
    static let normalSpeech: [SpeechFixture] = [
        SpeechFixture(
            fileName: "normal_ldc93s1.wav",
            id: "ldc93s1",
            reference: "She had your dark suit in greasy wash water all year.",
            source: "LDC93S1 / DeepSpeech smoke (public ASR sample)"
        ),
        SpeechFixture(
            fileName: "librispeech_5694_0000.wav",
            id: "ls_5694_0000",
            reference: "Advance into Tennessee",
            source: "LibriSpeech dev-clean-2 5694-64038-0000 (CC BY 4.0)"
        ),
        SpeechFixture(
            fileName: "librispeech_5694_0001.wav",
            id: "ls_5694_0001",
            reference: "Yank says what you doing Johnny",
            source: "LibriSpeech dev-clean-2 5694-64038-0001 (CC BY 4.0)"
        ),
        SpeechFixture(
            fileName: "librispeech_3000_0000.wav",
            id: "ls_3000_0000",
            reference: "Shasta rambles and Modoc memories",
            source: "LibriSpeech dev-clean-2 3000-15664-0000 (CC BY 4.0)"
        ),
        SpeechFixture(
            fileName: "librispeech_84_0000.wav",
            id: "ls_84_0000",
            reference: "But with full ravishment the hours of prime singing received they in the midst of leaves that ever bore a burden to their rhymes",
            source: "LibriSpeech dev-clean-2 84-121550-0000 (CC BY 4.0)"
        ),
        SpeechFixture(
            fileName: "librispeech_84_0001.wav",
            id: "ls_84_0001",
            reference: "All waters that on earth most limpid are would seem to have within themselves some mixture compared with that which nothing doth conceal",
            source: "LibriSpeech dev-clean-2 84-121550-0001 (CC BY 4.0)"
        ),
    ]

    /// Shorter subset for soft-gain / always-on smoke (fewer long poetic lines).
    static let normalSpeechCore: [SpeechFixture] = normalSpeech.filter {
        ["ldc93s1", "ls_5694_0000", "ls_5694_0001", "ls_3000_0000"].contains($0.id)
    }

    /// Regression ceilings for real human speech (tighten only).
    enum Budgets {
        /// Clean LibriSpeech / LDC at natural level.
        static let normalMeanMajorWER: Double = 0.20
        static let normalMeanWER: Double = 0.28
        static let normalPerPhraseMajorWER: Double = 0.50
        /// Softened (gain 0.15) still usable after softInputGain + energy fix.
        static let softMeanMajorWER: Double = 0.35
        static let softMeanWER: Double = 0.45
        static let softMinNonEmptyRate: Double = 0.75
    }
}
