// DictationDictionaryTests.swift — Custom vocabulary apply + merge order.

import Testing
import Foundation
@testable import Chirp

@Suite("DictationDictionary", .serialized)
struct DictationDictionaryTests {

    private func withCleanOverrides(_ body: () -> Void) {
        let prev = DictationDictionary.testOverrides
        DictationDictionary.testOverrides = [:]
        defer { DictationDictionary.testOverrides = prev }
        body()
    }

    @Test("built-in tech phrases rewrite")
    func builtIn() {
        withCleanOverrides {
            #expect(DictationDictionary.apply("open get hub") == "open GitHub")
            #expect(DictationDictionary.apply("I use vs code") == "I use VS Code")
            #expect(DictationDictionary.apply("build with swift ui") == "build with SwiftUI")
            #expect(DictationDictionary.apply("on mac os") == "on macOS")
            #expect(DictationDictionary.apply("write type script") == "write TypeScript")
            #expect(DictationDictionary.apply("learn java script") == "learn JavaScript")
            #expect(DictationDictionary.apply("use name space") == "use namespace")
            #expect(DictationDictionary.apply("deploy k eight s") == "deploy k8s")
            #expect(DictationDictionary.apply("query graph ql") == "query GraphQL")
            #expect(DictationDictionary.apply("run post gres") == "run PostgreSQL")
            #expect(DictationDictionary.apply("use postgres ql") == "use PostgreSQL")
        }
    }

    @Test("test overrides win over built-in")
    func overridesWin() {
        withCleanOverrides {
            DictationDictionary.testOverrides = ["get hub": "GitLab"]
            #expect(DictationDictionary.apply("open get hub") == "open GitLab")
        }
    }

    @Test("longest key wins")
    func longestKey() {
        withCleanOverrides {
            DictationDictionary.testOverrides = [
                "hub": "HUB",
                "get hub": "GitHub",
            ]
            #expect(DictationDictionary.apply("get hub") == "GitHub")
        }
    }

    @Test("integrated via TextPostProcessor")
    func viaPostProcessor() {
        withCleanOverrides {
            #expect(TextPostProcessor.process("open get hub please") == "open GitHub please")
        }
    }

    @Test("user save and load round-trip")
    func userPersistence() {
        withCleanOverrides {
            let key = DictationDictionary.defaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            defer {
                if let previous {
                    UserDefaults.standard.set(previous, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

            DictationDictionary.saveUserEntries(["chirp app": "Chirp"])
            #expect(DictationDictionary.userEntries()["chirp app"] == "Chirp")
            #expect(DictationDictionary.apply("launch chirp app now") == "launch Chirp now")
        }
    }
}
