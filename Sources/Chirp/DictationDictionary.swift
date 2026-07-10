// DictationDictionary.swift — User/custom phrase replacements for dictation.
// SOTA dictation apps expose a custom dictionary so names and jargon stick.
// Applied in TextPostProcessor after built-in phrase fixes.
// Pure apply() is testable; persistence is UserDefaults.

import Foundation

enum DictationDictionary {
    static let defaultsKey = "chirp.dictationDictionary"

    /// Test-only overrides (merged on top of saved entries).
    /// `nonisolated(unsafe)` — tests set this on the main test thread only.
    nonisolated(unsafe) static var testOverrides: [String: String] = [:]

    /// Built-in seeds (low risk). User entries win on key conflict.
    static let builtIn: [String: String] = [
        // Common tech / product ASR confusions
        "get hub": "GitHub",
        "git hub": "GitHub",
        "vs code": "VS Code",
        "x code": "Xcode",
        "swift ui": "SwiftUI",
        "mac os": "macOS",
        "i phone": "iPhone",
        "i pad": "iPad",
        "i cloud": "iCloud",
    ]

    /// Load user replacements from UserDefaults (keys stored lowercase).
    static func userEntries() -> [String: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in raw {
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !val.isEmpty else { continue }
            out[key] = val
        }
        return out
    }

    static func saveUserEntries(_ entries: [String: String]) {
        var normalized: [String: String] = [:]
        for (k, v) in entries {
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !val.isEmpty else { continue }
            normalized[key] = val
        }
        UserDefaults.standard.set(normalized, forKey: defaultsKey)
    }

    /// Merged map: built-in < user < testOverrides (later wins).
    static func allEntries() -> [String: String] {
        var map = builtIn
        for (k, v) in userEntries() { map[k] = v }
        for (k, v) in testOverrides {
            map[k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = v
        }
        return map
    }

    /// Apply phrase replacements longest-key-first (case-insensitive whole phrases).
    static func apply(_ text: String) -> String {
        let entries = allEntries()
        guard !entries.isEmpty else { return text }

        // Longest keys first so "git hub" wins over "hub"
        let keys = entries.keys.sorted { $0.count > $1.count }
        var result = text
        for key in keys {
            guard let replacement = entries[key] else { continue }
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: key) + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
