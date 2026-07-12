// CommandHotwordsTests.swift — Pure dual of command ASR bias phrase list.

import Foundation
import Testing
@testable import Chirp

@Suite("CommandHotwords")
struct CommandHotwordsTests {

    @Test("phrases are multi-word, lowercased, unique")
    func phrasesShape() {
        let p = CommandHotwords.phrases
        #expect(!p.isEmpty)
        #expect(p.count >= 20)
        for phrase in p {
            #expect(phrase == phrase.lowercased())
            #expect(!phrase.hasPrefix(" "))
            #expect(!phrase.hasSuffix(" "))
            #expect(phrase.split(separator: " ").count >= 2, "drop single-token: \(phrase)")
        }
        #expect(Set(p).count == p.count, "no duplicates")
    }

    @Test("core Dragon commands are boosted")
    func coreCommandsPresent() {
        let p = Set(CommandHotwords.phrases)
        #expect(p.contains("scratch that"))
        #expect(p.contains("select that"))
        #expect(p.contains("select again"))
        #expect(p.contains("press escape"))
        #expect(p.contains("cap that"))
        #expect(p.contains("new paragraph"))
    }

    @Test("file body is newline separated with trailing newline")
    func fileBody() {
        let body = CommandHotwords.fileBody(phrases: ["scratch that", "select that"])
        #expect(body == "scratch that\nselect that\n")
        #expect(CommandHotwords.fileBody(phrases: []).isEmpty)
    }

    @Test("stream body is slash separated")
    func streamBody() {
        #expect(
            CommandHotwords.streamBody(phrases: ["scratch that", "select that"])
                == "scratch that/select that"
        )
        #expect(CommandHotwords.streamBody(phrases: []).isEmpty)
    }

    @Test("normalize collapses whitespace and lowercases")
    func normalize() {
        #expect(CommandHotwords.normalize("  Select  That ") == "select that")
        #expect(CommandHotwords.normalize("") == "")
    }

    @Test("ensureFileOnDisk writes readable hotwords file")
    func ensureFileOnDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-hotwords-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = CommandHotwords.ensureFileOnDisk(directory: tmp)
        #expect(path != nil)
        let text = try String(contentsOfFile: path!, encoding: .utf8)
        #expect(text.contains("scratch that"))
        #expect(text.contains("select again"))
        #expect(text.hasSuffix("\n"))
    }

    @Test("tokenForm prefers bare; marked only when allowMarked")
    func tokenForm() {
        let mark = String(CommandHotwords.spWordMark)
        let tokens: Set<String> = [mark + "that", mark + "cap", "go", "to", "end"]
        #expect(CommandHotwords.tokenForm(word: "go", tokens: tokens) == "go")
        #expect(CommandHotwords.tokenForm(word: "that", tokens: tokens) == nil) // bare only
        #expect(
            CommandHotwords.tokenForm(word: "that", tokens: tokens, allowMarked: true)
                == mark + "that"
        )
        #expect(CommandHotwords.tokenForm(word: "missing", tokens: tokens) == nil)
    }

    @Test("encodePhrase bare-only for sherpa without bpe_vocab")
    func encodePhrase() {
        let mark = String(CommandHotwords.spWordMark)
        let tokens: Set<String> = ["go", "to", "end", "press", "enter", mark + "that"]
        #expect(CommandHotwords.encodePhrase("go to end", tokens: tokens) == "go to end")
        #expect(CommandHotwords.encodePhrase("press enter", tokens: tokens) == "press enter")
        // ▁that alone is not used unless allowMarked
        #expect(CommandHotwords.encodePhrase("cut that", tokens: tokens) == nil)
        #expect(
            CommandHotwords.encodePhrase("cut that", tokens: tokens.union(["cut"]), allowMarked: true)
                == "cut \(mark)that"
        )
        #expect(CommandHotwords.encodePhrase("cap", tokens: tokens) == nil) // single word
    }

    @Test("encodablePhrases filters and dedupes encoded lines")
    func encodablePhrases() {
        let tokens: Set<String> = ["go", "to", "end", "press", "enter", "tab"]
        let enc = CommandHotwords.encodablePhrases(
            from: ["go to end", "spell mode", "press enter", "go to end"],
            tokens: tokens
        )
        #expect(enc.count == 2)
        #expect(enc.contains("go to end"))
        #expect(enc.contains("press enter"))
        #expect(!enc.contains { $0.contains("spell") })
    }

    @Test("shouldEnableHotwords gates sparse lists")
    func shouldEnableHotwords() {
        #expect(!CommandHotwords.shouldEnableHotwords(encodableCount: 0))
        #expect(!CommandHotwords.shouldEnableHotwords(encodableCount: 2))
        #expect(
            !CommandHotwords.shouldEnableHotwords(
                encodableCount: CommandHotwords.minUsefulPhrases - 1
            )
        )
        #expect(
            CommandHotwords.shouldEnableHotwords(
                encodableCount: CommandHotwords.minUsefulPhrases
            )
        )
        #expect(CommandHotwords.shouldEnableHotwords(encodableCount: 20))
    }

    @Test("ensureFileOnDisk skips sparse token-filtered lists (prefer greedy)")
    func ensureFileOnDiskSparseSkips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-hotwords-sparse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let tokensFile = tmp.appendingPathComponent("tokens.txt")
        // Only enough bare tokens for 2 seed phrases — below minUsefulPhrases.
        try """
        go 1
        to 2
        end 3
        press 4
        enter 5
        """.write(to: tokensFile, atomically: true, encoding: .utf8)

        let path = CommandHotwords.ensureFileOnDisk(
            directory: tmp,
            tokensPath: tokensFile.path
        )
        #expect(path == nil, "sparse hotwords must not enable beam search")
    }

    @Test("ensureFileOnDisk with tokens writes when enough bare phrases")
    func ensureFileOnDiskTokenFiltered() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-hotwords-tok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let tokensFile = tmp.appendingPathComponent("tokens.txt")
        // Bare tokens for ≥ minUsefulPhrases seed phrases.
        try """
        go 1
        to 2
        end 3
        start 4
        press 5
        enter 6
        tab 7
        space 8
        new 9
        line 10
        paragraph 11
        """.write(to: tokensFile, atomically: true, encoding: .utf8)

        let path = CommandHotwords.ensureFileOnDisk(
            directory: tmp,
            tokensPath: tokensFile.path
        )
        #expect(path != nil)
        let text = try String(contentsOfFile: path!, encoding: .utf8)
        #expect(text.contains("go to end"))
        #expect(text.contains("press enter"))
        #expect(!text.contains("spell"))
        #expect(!text.contains("scratch"))
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        #expect(lines.count >= CommandHotwords.minUsefulPhrases)
    }

    @Test("loadTokenSet reads first column of tokens.txt")
    func loadTokenSet() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-tokens-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mark = String(CommandHotwords.spWordMark)
        try "\(mark)that 1050\n\(mark)cap 2112\n".write(to: tmp, atomically: true, encoding: .utf8)
        let set = CommandHotwords.loadTokenSet(from: tmp.path)
        #expect(set?.contains(mark + "that") == true)
        #expect(set?.contains(mark + "cap") == true)
        #expect(set?.contains("that") == false)
    }
}
