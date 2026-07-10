// TranscriptionScoring.swift — WER / CER metrics for ranking ASR quality.
// Pure functions, no model dependency. Used by unit tests and corpus pipeline tests.

import Foundation

/// Result of scoring one hypothesis against a reference transcript.
struct TranscriptionScore: Sendable, Comparable {
    let id: String
    let reference: String
    let hypothesis: String
    /// Word error rate in [0, ∞). 0 = perfect. Can exceed 1.0 if hyp is much longer.
    let wer: Double
    /// Character error rate in [0, ∞).
    let cer: Double
    /// Humanized WER: ignores pure a/an/the article substitutions (readability-minor).
    let majorWER: Double
    let wordEdits: Int
    let wordCount: Int
    let charEdits: Int
    let charCount: Int

    static func < (lhs: TranscriptionScore, rhs: TranscriptionScore) -> Bool {
        // Lower WER ranks better; tie-break on majorWER, CER, then id.
        if lhs.wer != rhs.wer { return lhs.wer < rhs.wer }
        if lhs.majorWER != rhs.majorWER { return lhs.majorWER < rhs.majorWER }
        if lhs.cer != rhs.cer { return lhs.cer < rhs.cer }
        return lhs.id < rhs.id
    }

    var summaryLine: String {
        let werPct = String(format: "%.1f%%", wer * 100)
        let majorPct = String(format: "%.1f%%", majorWER * 100)
        let cerPct = String(format: "%.1f%%", cer * 100)
        return "[\(id)] WER=\(werPct) major=\(majorPct) CER=\(cerPct) ref=\"\(reference)\" hyp=\"\(hypothesis)\""
    }
}

/// Aggregate ranking report over a corpus.
struct TranscriptionRanking: Sendable {
    let scores: [TranscriptionScore] // sorted best → worst (ascending WER)

    var meanWER: Double {
        guard !scores.isEmpty else { return 0 }
        return scores.map(\.wer).reduce(0, +) / Double(scores.count)
    }

    var meanMajorWER: Double {
        guard !scores.isEmpty else { return 0 }
        return scores.map(\.majorWER).reduce(0, +) / Double(scores.count)
    }

    var medianWER: Double {
        guard !scores.isEmpty else { return 0 }
        let sorted = scores.map(\.wer).sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    var meanCER: Double {
        guard !scores.isEmpty else { return 0 }
        return scores.map(\.cer).reduce(0, +) / Double(scores.count)
    }

    var worst: TranscriptionScore? { scores.last }
    var best: TranscriptionScore? { scores.first }

    /// Human-readable leaderboard (best first).
    var leaderboard: String {
        var lines: [String] = []
        lines.append("=== ASR Ranking (best → worst) n=\(scores.count) ===")
        lines.append(String(format:
            "mean WER=%.1f%%  mean major=%.1f%%  median WER=%.1f%%  mean CER=%.1f%%",
            meanWER * 100, meanMajorWER * 100, medianWER * 100, meanCER * 100))
        for (i, s) in scores.enumerated() {
            lines.append(String(format: "  #%d %@", i + 1, s.summaryLine))
        }
        return lines.joined(separator: "\n")
    }
}

enum TranscriptionScoring {
    /// Normalize for comparison: lowercase, strip punctuation, collapse whitespace,
    /// map common spoken numbers / am-pm variants so TTS vs ASR ITN does not inflate WER.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "'" {
                return Character(scalar)
            }
            return " "
        }
        var tokens = String(stripped)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        // Spoken number words → digits (small set used in corpus).
        let numberWords: [String: String] = [
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
            "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
            "ten": "10", "eleven": "11", "twelve": "12",
        ]
        tokens = tokens.map { numberWords[$0] ?? $0 }

        // "p.m." / "a.m." become ["p","m"] / ["a","m"] after punctuation→space.
        var merged: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, tokens[i] == "p", tokens[i + 1] == "m" {
                merged.append("pm")
                i += 2
            } else if i + 1 < tokens.count, tokens[i] == "a", tokens[i + 1] == "m" {
                merged.append("am")
                i += 2
            } else {
                let t = tokens[i]
                switch t {
                case "a.m", "am": merged.append("am")
                case "p.m", "pm": merged.append("pm")
                default: merged.append(t)
                }
                i += 1
            }
        }

        return merged.joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        let n = normalize(text)
        guard !n.isEmpty else { return [] }
        return n.split(separator: " ").map(String.init)
    }

    /// Levenshtein edit distance between two sequences.
    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let n = a.count
        let m = b.count
        if n == 0 { return m }
        if m == 0 { return n }

        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,      // deletion
                    curr[j - 1] + 1,  // insertion
                    prev[j - 1] + cost // substitution
                )
            }
            prev = curr
        }
        return prev[m]
    }

    /// Word Error Rate = edits / |reference words|. Empty ref → 0 if hyp empty else 1.
    static func wordErrorRate(reference: String, hypothesis: String) -> (wer: Double, edits: Int, count: Int) {
        let refW = words(reference)
        let hypW = words(hypothesis)
        if refW.isEmpty {
            return (hypW.isEmpty ? 0 : 1, hypW.isEmpty ? 0 : hypW.count, 0)
        }
        let edits = editDistance(refW, hypW)
        return (Double(edits) / Double(refW.count), edits, refW.count)
    }

    private static let minorArticles: Set<String> = ["a", "an", "the"]

    /// Alignment-based major-error count: article↔article substitutions cost 0.
    /// Insertions/deletions of content words and non-article substitutions still count.
    static func majorWordEdits(reference: [String], hypothesis: [String]) -> Int {
        let n = reference.count
        let m = hypothesis.count
        if n == 0 { return m == 0 ? 0 : hypothesis.filter { !minorArticles.contains($0) }.count }
        if m == 0 { return reference.filter { !minorArticles.contains($0) }.count }

        // DP with operation kinds reconstructed via backpointers
        var dist = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dist[i][0] = i }
        for j in 0...m { dist[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                dist[i][j] = min(
                    dist[i - 1][j] + 1,
                    dist[i][j - 1] + 1,
                    dist[i - 1][j - 1] + cost
                )
            }
        }

        // Backtrace and count major edits only
        var i = n, j = m
        var major = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], dist[i][j] == dist[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, dist[i][j] == dist[i - 1][j - 1] + 1 {
                // substitution
                let r = reference[i - 1], h = hypothesis[j - 1]
                if !(minorArticles.contains(r) && minorArticles.contains(h)) {
                    major += 1
                }
                i -= 1; j -= 1
            } else if i > 0, dist[i][j] == dist[i - 1][j] + 1 {
                if !minorArticles.contains(reference[i - 1]) { major += 1 }
                i -= 1
            } else if j > 0, dist[i][j] == dist[i][j - 1] + 1 {
                if !minorArticles.contains(hypothesis[j - 1]) { major += 1 }
                j -= 1
            } else {
                break
            }
        }
        return major
    }

    /// Humanized WER focusing on meaning-changing errors (Apple HEWER-inspired).
    static func majorWordErrorRate(reference: String, hypothesis: String) -> Double {
        let refW = words(reference)
        let hypW = words(hypothesis)
        if refW.isEmpty {
            return hypW.filter { !minorArticles.contains($0) }.isEmpty ? 0 : 1
        }
        let edits = majorWordEdits(reference: refW, hypothesis: hypW)
        return Double(edits) / Double(refW.count)
    }

    /// Character Error Rate over normalized strings (spaces kept).
    static func charErrorRate(reference: String, hypothesis: String) -> (cer: Double, edits: Int, count: Int) {
        let refC = Array(normalize(reference))
        let hypC = Array(normalize(hypothesis))
        if refC.isEmpty {
            return (hypC.isEmpty ? 0 : 1, hypC.isEmpty ? 0 : hypC.count, 0)
        }
        let edits = editDistance(refC, hypC)
        return (Double(edits) / Double(refC.count), edits, refC.count)
    }

    static func score(id: String, reference: String, hypothesis: String) -> TranscriptionScore {
        let w = wordErrorRate(reference: reference, hypothesis: hypothesis)
        let c = charErrorRate(reference: reference, hypothesis: hypothesis)
        let major = majorWordErrorRate(reference: reference, hypothesis: hypothesis)
        return TranscriptionScore(
            id: id,
            reference: reference,
            hypothesis: hypothesis,
            wer: w.wer,
            cer: c.cer,
            majorWER: major,
            wordEdits: w.edits,
            wordCount: w.count,
            charEdits: c.edits,
            charCount: c.count
        )
    }

    /// Score each pair and return ranking sorted best → worst.
    static func rank(_ items: [(id: String, reference: String, hypothesis: String)]) -> TranscriptionRanking {
        let scores = items.map { score(id: $0.id, reference: $0.reference, hypothesis: $0.hypothesis) }
            .sorted()
        return TranscriptionRanking(scores: scores)
    }
}
