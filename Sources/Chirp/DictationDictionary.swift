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
        "get lab": "GitLab",
        "git lab": "GitLab",
        "bit bucket": "Bitbucket",
        "vs code": "VS Code",
        "x code": "Xcode",
        "swift ui": "SwiftUI",
        "mac os": "macOS",
        "i phone": "iPhone",
        "i pad": "iPad",
        "i cloud": "iCloud",
        "type script": "TypeScript",
        "java script": "JavaScript",
        "node j s": "Node.js",
        "react native": "React Native",
        "j query": "jQuery",
        "name space": "namespace",
        "k eight s": "k8s",
        "cube control": "kubectl",
        "kube control": "kubectl",
        "cube net ease": "Kubernetes",
        "graph ql": "GraphQL",
        "post gres": "PostgreSQL",
        "postgres ql": "PostgreSQL",
        "mongo d b": "MongoDB",
        "elastic search": "Elasticsearch",
        "open a i": "OpenAI",
        "chat g p t": "ChatGPT",
        "hugging face": "Hugging Face",
        "data dog": "Datadog",
        "c i c d": "CI/CD",
        "docker": "Docker",
        "redis": "Redis",
        // Claude Code ASR: "cloud code" only (avoid bare "claude" — common name)
        "cloud code": "Claude Code",
        // Coding / web-stack ASR confusions (low risk; skip short "p r", "type o")
        "pull request": "PR",
        "next j s": "Next.js",
        "fast a p i": "FastAPI",
        "tail wind": "Tailwind",
        "home brew": "Homebrew",
        "py torch": "PyTorch",
        "l l m": "LLM",
        "web pack": "webpack",
        "vs codium": "VSCodium",
        "cloud flare": "Cloudflare",
        "super base": "Supabase",
        "fire base": "Firebase",
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
