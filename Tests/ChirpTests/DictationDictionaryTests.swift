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
            #expect(DictationDictionary.apply("watch you tube") == "watch YouTube")
            #expect(DictationDictionary.apply("connect to wi fi") == "connect to Wi-Fi")
            #expect(DictationDictionary.apply("wi fi password") == "Wi-Fi password")
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
            #expect(DictationDictionary.apply("run docker compose") == "run Docker compose")
            #expect(DictationDictionary.apply("use bay zel") == "use Bazel")
            #expect(DictationDictionary.apply("talk to g rock") == "talk to Grok")
            #expect(DictationDictionary.apply("built with x a i") == "built with xAI")
            #expect(DictationDictionary.apply("export on nx") == "export ONNX")
            #expect(DictationDictionary.apply("run async await") == "run async/await")
            #expect(DictationDictionary.apply("my mac book") == "my MacBook")
            #expect(DictationDictionary.apply("use cube control apply") == "use kubectl apply")
            #expect(DictationDictionary.apply("kube control get pods") == "kubectl get pods")
            #expect(DictationDictionary.apply("deploy cube net ease") == "deploy Kubernetes")
            #expect(DictationDictionary.apply("build react native app") == "build React Native app")
            #expect(DictationDictionary.apply("install node j s") == "install Node.js")
            #expect(DictationDictionary.apply("ask chat g p t") == "ask ChatGPT")
            #expect(DictationDictionary.apply("open cloud code") == "open Claude Code")
            #expect(DictationDictionary.apply("push to get lab") == "push to GitLab")
            #expect(DictationDictionary.apply("clone bit bucket repo") == "clone Bitbucket repo")
            #expect(DictationDictionary.apply("load j query") == "load jQuery")
            #expect(DictationDictionary.apply("query mongo d b") == "query MongoDB")
            #expect(DictationDictionary.apply("cache in redis") == "cache in Redis")
            #expect(DictationDictionary.apply("index elastic search") == "index Elasticsearch")
            #expect(DictationDictionary.apply("call open a i") == "call OpenAI")
            #expect(DictationDictionary.apply("from hugging face") == "from Hugging Face")
            #expect(DictationDictionary.apply("metrics in data dog") == "metrics in Datadog")
            #expect(DictationDictionary.apply("setup c i c d") == "setup CI/CD")
            // Low-risk ASR confusions (coding / web stack)
            #expect(DictationDictionary.apply("open pull request") == "open PR")
            #expect(DictationDictionary.apply("use next j s") == "use Next.js")
            #expect(DictationDictionary.apply("build fast a p i") == "build FastAPI")
            #expect(DictationDictionary.apply("style with tail wind") == "style with Tailwind")
            #expect(DictationDictionary.apply("install home brew") == "install Homebrew")
            #expect(DictationDictionary.apply("train py torch") == "train PyTorch")
            #expect(DictationDictionary.apply("run l l m") == "run LLM")
            #expect(DictationDictionary.apply("configure web pack") == "configure webpack")
            #expect(DictationDictionary.apply("open vs codium") == "open VSCodium")
            #expect(DictationDictionary.apply("use cloud flare") == "use Cloudflare")
            #expect(DictationDictionary.apply("deploy super base") == "deploy Supabase")
            #expect(DictationDictionary.apply("use fire base") == "use Firebase")
        }
    }

    @Test("longest multi-word seeds win over shorter keys")
    func builtInLongestKey() {
        withCleanOverrides {
            // Longer keys applied first; multi-word phrases stay intact
            #expect(DictationDictionary.apply("cube net ease cluster") == "Kubernetes cluster")
            #expect(DictationDictionary.apply("chat g p t please") == "ChatGPT please")
            #expect(DictationDictionary.apply("elastic search index") == "Elasticsearch index")
            #expect(DictationDictionary.apply("hugging face model") == "Hugging Face model")
            #expect(DictationDictionary.apply("react native and type script") == "React Native and TypeScript")
            #expect(DictationDictionary.apply("fast a p i server") == "FastAPI server")
            #expect(DictationDictionary.apply("next j s app") == "Next.js app")
            #expect(DictationDictionary.apply("pull request ready") == "PR ready")
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
            #expect(TextPostProcessor.process("open you tube please") == "open YouTube please")
            #expect(TextPostProcessor.process("join the wi fi") == "join the Wi-Fi")
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
