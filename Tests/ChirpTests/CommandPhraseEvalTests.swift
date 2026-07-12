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
}
