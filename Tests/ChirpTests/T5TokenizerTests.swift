import Testing
import Foundation
@testable import Chirp

@Suite("T5Tokenizer")
struct T5TokenizerTests {

    /// Helper: create a minimal tokenizer.json for testing.
    /// Uses a small vocabulary sufficient for encode/decode round-trip tests.
    private static func makeTestTokenizerPath() throws -> String {
        let vocab: [[Any]] = [
            ["<pad>", 0.0],
            ["</s>", 0.0],
            ["<unk>", 0.0],
            ["\u{2581}", -1.0],          // bare space marker
            ["\u{2581}hello", -2.0],
            ["\u{2581}world", -2.5],
            ["h", -5.0],
            ["e", -5.0],
            ["l", -5.0],
            ["o", -5.0],
            ["w", -5.0],
            ["r", -5.0],
            ["d", -5.0],
            ["\u{2581}fix", -2.0],
            ["\u{2581}grammar", -3.0],
            ["\u{2581}and", -2.0],
            ["\u{2581}punctuation", -3.5],
            [":", -4.0],
        ]
        let json: [String: Any] = [
            "model": ["vocab": vocab, "type": "Unigram"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let tmpDir = NSTemporaryDirectory()
        let path = "\(tmpDir)/test_tokenizer_\(UUID().uuidString).json"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("Loads vocabulary from tokenizer.json")
    func loadVocab() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        #expect(tokenizer.vocabSize == 18)
        #expect(tokenizer.padTokenID == 0)
        #expect(tokenizer.eosTokenID == 1)
        #expect(tokenizer.unkTokenID == 2)
    }

    @Test("Encode produces expected IDs with EOS")
    func encode() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let ids = tokenizer.encode("hello world")
        // Should end with EOS
        #expect(ids.last == tokenizer.eosTokenID)
        // Should not be empty
        #expect(ids.count > 1)
    }

    @Test("Decode strips special tokens and restores spaces")
    func decode() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let ids = tokenizer.encode("hello world")
        let decoded = tokenizer.decode(ids)
        #expect(decoded == "hello world")
    }

    @Test("Encode/decode round-trip preserves text")
    func roundTrip() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let texts = ["hello", "hello world", "fix grammar and punctuation:"]
        for text in texts {
            let decoded = tokenizer.decode(tokenizer.encode(text))
            #expect(decoded == text, "Round-trip failed for: \(text)")
        }
    }

    @Test("Empty string encodes to just EOS")
    func emptyEncode() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let ids = tokenizer.encode("")
        #expect(ids == [tokenizer.eosTokenID])
    }

    @Test("Decode skips pad and EOS tokens")
    func decodeSkipsSpecial() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let ids = [0, 4, 5, 1, 0]  // pad, hello, world, eos, pad
        let decoded = tokenizer.decode(ids)
        #expect(decoded == "hello world")
    }

    @Test("Unknown characters fall back to UNK token")
    func unknownChars() throws {
        let path = try Self.makeTestTokenizerPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokenizer = try T5Tokenizer(path: path)
        let ids = tokenizer.encode("xyz")
        // Should contain UNK tokens for unknown characters
        #expect(ids.contains(tokenizer.unkTokenID))
    }

    @Test("Throws on missing file")
    func missingFile() {
        #expect(throws: T5Tokenizer.TokenizerError.self) {
            _ = try T5Tokenizer(path: "/nonexistent/tokenizer.json")
        }
    }
}
