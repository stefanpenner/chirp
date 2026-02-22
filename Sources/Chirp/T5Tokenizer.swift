// T5Tokenizer.swift — Pure-Swift SentencePiece Unigram tokenizer for T5.
// Loads HuggingFace `tokenizer.json` (vocab + scores). Implements Viterbi-based
// Unigram segmentation for encode(), lookup-based decode().

import Foundation

/// SentencePiece Unigram tokenizer compatible with T5 models.
/// Loads from HuggingFace `tokenizer.json` format.
struct T5Tokenizer: Sendable {
    /// Vocab: token string -> (id, log-probability score)
    private let tokenToID: [String: Int]
    private let idToToken: [Int: String]
    private let scores: [String: Float]

    // Special tokens
    let padTokenID: Int      // <pad> = 0
    let eosTokenID: Int      // </s> = 1
    let unkTokenID: Int      // <unk> = 2
    let decoderStartTokenID: Int // <pad> = 0 for T5

    /// SentencePiece uses U+2581 (lower one eighth block) as word-boundary marker.
    static let spaceMarker: Character = "\u{2581}"
    static let spaceMarkerStr = String(spaceMarker)

    enum TokenizerError: Error, LocalizedError {
        case fileNotFound(String)
        case invalidFormat(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "Tokenizer file not found: \(path)"
            case .invalidFormat(let msg): return "Invalid tokenizer format: \(msg)"
            }
        }
    }

    /// Load from a HuggingFace `tokenizer.json` file.
    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw TokenizerError.fileNotFound(path)
        }

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json else { throw TokenizerError.invalidFormat("root is not object") }

        // Extract vocab from model.vocab (array of [token, score] pairs)
        guard let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [[Any]] else {
            throw TokenizerError.invalidFormat("missing model.vocab")
        }

        var tokenToID: [String: Int] = [:]
        var idToToken: [Int: String] = [:]
        var scores: [String: Float] = [:]

        for (idx, entry) in vocab.enumerated() {
            guard entry.count >= 2,
                  let token = entry[0] as? String else { continue }
            let score: Float
            if let s = entry[1] as? Double {
                score = Float(s)
            } else if let s = entry[1] as? Float {
                score = s
            } else {
                score = 0
            }
            tokenToID[token] = idx
            idToToken[idx] = token
            scores[token] = score
        }

        self.tokenToID = tokenToID
        self.idToToken = idToToken
        self.scores = scores

        // T5 special token IDs (standard for T5)
        self.padTokenID = tokenToID["<pad>"] ?? 0
        self.eosTokenID = tokenToID["</s>"] ?? 1
        self.unkTokenID = tokenToID["<unk>"] ?? 2
        self.decoderStartTokenID = self.padTokenID
    }

    // MARK: - Encode

    /// Encode text to token IDs. Prepends SentencePiece space marker, appends EOS.
    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [eosTokenID] }

        // SentencePiece convention: prepend space marker to the text
        let normalized = Self.spaceMarkerStr + text.replacingOccurrences(of: " ", with: Self.spaceMarkerStr)

        let tokens = unigramTokenize(normalized)
        var ids = tokens.map { tokenToID[$0] ?? unkTokenID }
        ids.append(eosTokenID)
        return ids
    }

    /// Viterbi-based Unigram tokenization.
    /// Finds the segmentation that maximizes the sum of log-probabilities.
    private func unigramTokenize(_ text: String) -> [String] {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return [] }

        // bestScore[i] = best log-prob score for text[0..<i]
        // bestEnd[i] = length of the last token in the best path to position i
        var bestScore = [Float](repeating: -.infinity, count: n + 1)
        var bestEnd = [Int](repeating: 0, count: n + 1)
        bestScore[0] = 0

        for i in 0..<n {
            guard bestScore[i] > -.infinity else { continue }
            // Try all substrings starting at position i
            let maxLen = min(n - i, 64) // SentencePiece max token length is typically small
            for len in 1...maxLen {
                let substr = String(chars[i..<(i + len)])
                let score: Float
                if let s = scores[substr] {
                    score = s
                } else if len == 1 {
                    // Single character fallback (treat as UNK with penalty)
                    score = -100.0
                } else {
                    continue
                }

                let newScore = bestScore[i] + score
                if newScore > bestScore[i + len] {
                    bestScore[i + len] = newScore
                    bestEnd[i + len] = len
                }
            }
        }

        // Backtrack to find the best segmentation
        var tokens: [String] = []
        var pos = n
        while pos > 0 {
            let len = bestEnd[pos]
            if len == 0 {
                // Unreachable segment — emit single char as UNK
                pos -= 1
                tokens.append(String(chars[pos]))
                continue
            }
            let start = pos - len
            tokens.append(String(chars[start..<pos]))
            pos = start
        }
        tokens.reverse()
        return tokens
    }

    // MARK: - Decode

    /// Decode token IDs back to text. Strips SentencePiece markers.
    func decode(_ ids: [Int]) -> String {
        var pieces: [String] = []
        for id in ids {
            if id == eosTokenID || id == padTokenID { continue }
            if let token = idToToken[id] {
                pieces.append(token)
            }
        }
        let joined = pieces.joined()
        // Replace SentencePiece space markers with actual spaces, then trim leading space
        return joined
            .replacingOccurrences(of: Self.spaceMarkerStr, with: " ")
            .trimmingCharacters(in: .init(charactersIn: " "))
    }

    /// Vocabulary size.
    var vocabSize: Int { tokenToID.count }
}
