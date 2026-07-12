// CommandPhraseEvalTests.swift — Pure dual of command recognition hit rate.

import Testing
@testable import Chirp

@Suite("CommandPhraseEval")
struct CommandPhraseEvalTests {

    @Test("golden trials all hit (perfect + near-miss ASR)")
    func goldenHitRateIsPerfect() {
        let rate = CommandPhraseEval.hitRate(CommandPhraseEval.goldenTrials)
        #expect(rate == 1.0, "golden miss rate \(1 - rate)")
        for t in CommandPhraseEval.goldenTrials {
            #expect(
                CommandPhraseEval.hit(t),
                "miss hyp=\"\(t.hyp)\" got \(DictationCommand.parse(t.hyp))"
            )
        }
    }

    @Test("hitRate empty is vacuous 1")
    func emptyHitRate() {
        #expect(CommandPhraseEval.hitRate([]) == 1.0)
    }

    @Test("hitRate counts partial misses")
    func partialHitRate() {
        let trials = [
            CommandPhraseEval.Trial(hyp: "scratch that", expected: .scratchThat(count: 1)),
            CommandPhraseEval.Trial(hyp: "hello world", expected: .scratchThat(count: 1)),
        ]
        #expect(abs(CommandPhraseEval.hitRate(trials) - 0.5) < 1e-9)
    }

    @Test("command-bias hotwords parse as DictationCommand")
    func commandHotwordsParse() {
        let phrases = CommandPhraseEval.commandBiasPhrases()
        #expect(!phrases.isEmpty)
        #expect(CommandPhraseEval.allCommandHotwordsParse(phrases: phrases))
        for p in phrases {
            #expect(
                DictationCommand.parse(p).isCommand,
                "hotword \"\(p)\" must parse as a command (got .none)"
            )
        }
    }

    @Test("content-only and open-phrase hotwords are classified")
    func contentAndOpenExcludedFromParseGate() {
        #expect(CommandPhraseEval.contentOnlyHotwords.contains("new line"))
        #expect(CommandPhraseEval.openPhraseHotwords.contains("resume with"))
        let bias = Set(CommandPhraseEval.commandBiasPhrases())
        #expect(!bias.contains("new line"))
        #expect(!bias.contains("resume with"))
    }

    @Test("soak phrase list is non-empty and self-consistent")
    func soakPhrasesSelfConsistent() {
        #expect(CommandPhraseEval.soakPhrases.count >= 8)
        for item in CommandPhraseEval.soakPhrases {
            #expect(
                DictationCommand.parse(item.spoken) == item.expected,
                "soak spoken=\"\(item.spoken)\" must parse to expected without ASR"
            )
        }
        #expect(CommandPhraseEval.soakMinHitRate >= 0.5)
        #expect(CommandPhraseEval.soakMinHitRate <= 1.0)
    }

    @Test("multi-voice soak subset is consistent and budgets ordered")
    func multiVoiceSoakConfig() {
        #expect(CommandPhraseEval.multiVoiceSoakPhrases.count >= 16)
        #expect(CommandPhraseEval.multiVoiceCandidates.count >= 6)
        // Accent coverage: UK + AU (and ideally IE/ZA/IN) in the probe list.
        let set = Set(CommandPhraseEval.multiVoiceCandidates)
        #expect(set.contains("Daniel"), "UK Daniel")
        #expect(set.contains("Karen"), "AU Karen")
        #expect(set.contains("Rishi"), "IN Rishi")
        #expect(!set.contains("Fred"), "skip novelty voices")
        #expect(CommandPhraseEval.multiVoiceMinVoices >= 2)
        // SOTA floors after 100% regional soak (raised from 0.85 / 0.70).
        #expect(CommandPhraseEval.multiVoiceSoakMinHitRate >= 0.90)
        #expect(CommandPhraseEval.multiVoiceMinPerVoiceHitRate >= 0.80)
        #expect(
            CommandPhraseEval.multiVoiceSoakMinHitRate
                <= CommandPhraseEval.soakMinHitRate
        )
        #expect(
            CommandPhraseEval.multiVoiceMinPerVoiceHitRate
                <= CommandPhraseEval.multiVoiceSoakMinHitRate
        )
        for item in CommandPhraseEval.multiVoiceSoakPhrases {
            #expect(DictationCommand.parse(item.spoken) == item.expected)
        }
    }

    @Test("minPerVoiceHitRate takes the worst voice")
    func minPerVoiceHitRate() {
        let good = CommandPhraseEval.Trial(hyp: "scratch that", expected: .scratchThat(count: 1))
        let bad = CommandPhraseEval.Trial(hyp: "hello", expected: .scratchThat(count: 1))
        let byVoice = [
            "A": [good, good],
            "B": [good, bad],
        ]
        #expect(CommandPhraseEval.multiVoicePooledHitRate(byVoice.values.flatMap { $0 }) == 0.75)
        #expect(abs(CommandPhraseEval.minPerVoiceHitRate(trialsByVoice: byVoice) - 0.5) < 1e-9)
        #expect(CommandPhraseEval.minPerVoiceHitRate(trialsByVoice: [:]) == 1.0)
    }
}
