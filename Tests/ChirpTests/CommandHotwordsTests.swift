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

    @Test("tokenForm prefers bare then SentencePiece ▁word")
    func tokenForm() {
        let mark = String(CommandHotwords.spWordMark)
        let tokens: Set<String> = [mark + "that", mark + "cap", "go"]
        #expect(CommandHotwords.tokenForm(word: "that", tokens: tokens) == mark + "that")
        #expect(CommandHotwords.tokenForm(word: "cap", tokens: tokens) == mark + "cap")
        #expect(CommandHotwords.tokenForm(word: "go", tokens: tokens) == "go")
        #expect(CommandHotwords.tokenForm(word: "missing", tokens: tokens) == nil)
    }

    @Test("encodePhrase maps to ▁ forms or drops unencodable")
    func encodePhrase() {
        let mark = String(CommandHotwords.spWordMark)
        let tokens: Set<String> = [mark + "cap", mark + "that", mark + "select"]
        #expect(
            CommandHotwords.encodePhrase("cap that", tokens: tokens)
                == "\(mark)cap \(mark)that"
        )
        #expect(CommandHotwords.encodePhrase("select that", tokens: tokens)
            == "\(mark)select \(mark)that")
        #expect(CommandHotwords.encodePhrase("spell that", tokens: tokens) == nil)
        #expect(CommandHotwords.encodePhrase("cap", tokens: tokens) == nil) // single word
    }

    @Test("encodablePhrases filters and dedupes encoded lines")
    func encodablePhrases() {
        let mark = String(CommandHotwords.spWordMark)
        let tokens: Set<String> = [mark + "cap", mark + "that", mark + "select"]
        let enc = CommandHotwords.encodablePhrases(
            from: ["cap that", "spell mode", "select that", "cap that"],
            tokens: tokens
        )
        #expect(enc.count == 2)
        #expect(enc.contains("\(mark)cap \(mark)that"))
        #expect(enc.contains("\(mark)select \(mark)that"))
        #expect(!enc.contains { $0.contains("spell") })
    }

    @Test("ensureFileOnDisk with tokens writes only encodable lines")
    func ensureFileOnDiskTokenFiltered() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-hotwords-tok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let mark = String(CommandHotwords.spWordMark)
        let tokensFile = tmp.appendingPathComponent("tokens.txt")
        // Minimal vocab like Parakeet: ▁word id
        try """
        \(mark)cap 1
        \(mark)that 2
        \(mark)select 3
        """.write(to: tokensFile, atomically: true, encoding: .utf8)

        let path = CommandHotwords.ensureFileOnDisk(
            directory: tmp,
            tokensPath: tokensFile.path
        )
        #expect(path != nil)
        let text = try String(contentsOfFile: path!, encoding: .utf8)
        #expect(text.contains("\(mark)cap \(mark)that"))
        #expect(text.contains("\(mark)select \(mark)that"))
        #expect(!text.contains("spell"))
        #expect(!text.contains("\nscratch ")) // unencodable without ▁scratch
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
