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
}
