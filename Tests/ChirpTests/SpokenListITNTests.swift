// SpokenListITNTests.swift — Numbered list voice commands.

import Testing
@testable import Chirp

@Suite("SpokenListITN")
struct SpokenListITNTests {

    @Test("number one and next number sequence")
    func sequence() {
        var c = 1
        let r = SpokenListITN.apply(
            "buy number one milk next number eggs number next bread",
            counter: &c
        )
        #expect(r.contains("1. "))
        #expect(r.contains("2. "))
        #expect(r.contains("3. "))
        #expect(r.contains("milk"))
        #expect(r.contains("eggs"))
        #expect(r.contains("bread"))
        #expect(c == 4)
    }

    @Test("explicit number three advances counter")
    func explicitNumber() {
        var c = 1
        let r = SpokenListITN.apply("number three first item next number second", counter: &c)
        #expect(r.contains("3. "))
        #expect(r.contains("4. "))
        #expect(c == 5)
    }

    @Test("digit form number 2")
    func digitForm() {
        var c = 1
        let r = SpokenListITN.apply("number 2 apples next number oranges", counter: &c)
        #expect(r.contains("2. "))
        #expect(r.contains("3. "))
        #expect(c == 4)
    }

    @Test("session counter survives across process calls")
    func sessionCounter() {
        TextPostProcessor.resetSessionFormatState()
        let a = TextPostProcessor.process("number one alpha")
        #expect(a.contains("1. "))
        let b = TextPostProcessor.process("next number beta")
        #expect(b.contains("2. "), "got \(b)")
        TextPostProcessor.resetSessionFormatState()
        let c = TextPostProcessor.process("next number gamma")
        #expect(c.contains("1. "), "reset should restart at 1, got \(c)")
    }

    @Test("does not rewrite bare number words without list command")
    func noFalsePositive() {
        #expect(SpokenListITN.apply("I need one more thing") == "I need one more thing")
    }
}
