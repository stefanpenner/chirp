// SpokenListITNTests.swift — Numbered list voice commands.

import Testing
@testable import Chirp

// Serialized: sessionListCounter + FormatSettings are process-global.
@Suite("SpokenListITN", .serialized)
struct SpokenListITNTests {

    @Test("number one and next number sequence")
    func sequence() {
        var c = 1
        let r = SpokenListITN.apply(
            "buy number one milk next number eggs number next bread",
            counter: &c
        )
        let lower = r.lowercased()
        #expect(r.contains("1. "))
        #expect(r.contains("2. "))
        #expect(r.contains("3. "))
        #expect(lower.contains("milk"))
        #expect(lower.contains("eggs"))
        #expect(lower.contains("bread"))
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

    @Test("end list resets counter")
    func endList() {
        var c = 1
        _ = SpokenListITN.apply("number one a next number b", counter: &c)
        #expect(c == 3)
        let r = SpokenListITN.apply("end list next number c", counter: &c)
        #expect(c == 2, "after end list, next number should be 1 → counter 2")
        #expect(r.contains("1. "), "got \(r)")
        #expect(r.contains("c") || r.contains("C"))
    }

    @Test("capitalizes after list marker")
    func capitalizesItem() {
        let r = SpokenListITN.apply("number one milk")
        #expect(r.contains("1. Milk") || r.contains("1. milk") == false)
        #expect(r.contains("1. "))
    }

    @Test("number twenty one compounds (tens + unit)")
    func compoundTensUnits() {
        var c = 1
        let r = SpokenListITN.apply(
            "number twenty one milk next number twenty two eggs number thirty bread",
            counter: &c
        )
        #expect(r.contains("21. "), "got \(r)")
        #expect(r.contains("22. "), "got \(r)")
        #expect(r.contains("30. "), "got \(r)")
        #expect(r.lowercased().contains("milk"))
        #expect(r.lowercased().contains("eggs"))
        #expect(c == 31)
        // Hyphenated ASR form
        #expect(SpokenListITN.apply("number twenty-one alpha").contains("21. "))
        // Teens still single-token
        #expect(SpokenListITN.apply("number fifteen beta").contains("15. "))
        // Must not leave residual "one" after tens-only match of "twenty one"
        let alone = SpokenListITN.apply("number twenty one item")
        #expect(!alone.lowercased().contains("one item"), "got \(alone)")
        #expect(alone.contains("21. "))
    }

    @Test("number one hundred compounds")
    func compoundHundred() {
        #expect(SpokenListITN.apply("number one hundred milk").contains("100. "))
        #expect(SpokenListITN.apply("number one hundred one alpha").contains("101. "))
        #expect(SpokenListITN.apply("number one hundred and five beta").contains("105. "))
        #expect(SpokenListITN.apply("number one hundred twenty gamma").contains("120. "))
        #expect(SpokenListITN.apply("number one hundred twenty one delta").contains("121. "))
        // Digit form
        #expect(SpokenListITN.apply("number 100 eggs").contains("100. "))
        #expect(SpokenListITN.apply("number 121 flour").contains("121. "))
        // No leftover "hundred" / "one" after rewrite
        let r = SpokenListITN.apply("number one hundred twenty one item")
        #expect(r.contains("121. "), "got \(r)")
        #expect(!r.lowercased().contains("hundred"), "got \(r)")
        #expect(!r.lowercased().contains("twenty"), "got \(r)")
        var c = 1
        _ = SpokenListITN.apply("number one hundred", counter: &c)
        #expect(c == 101)
        let next = SpokenListITN.apply("next number after", counter: &c)
        #expect(next.contains("101. "), "got \(next)")
    }

    @Test("number two–nine hundred compounds")
    func compoundMultiHundred() {
        #expect(SpokenListITN.apply("number two hundred milk").contains("200. "))
        #expect(SpokenListITN.apply("number three hundred one alpha").contains("301. "))
        #expect(SpokenListITN.apply("number two hundred and five beta").contains("205. "))
        #expect(SpokenListITN.apply("number five hundred twenty gamma").contains("520. "))
        #expect(SpokenListITN.apply("number nine hundred ninety nine delta").contains("999. "))
        #expect(SpokenListITN.apply("number two hundred twenty one item").contains("221. "))
        let r = SpokenListITN.apply("number two hundred twenty one item")
        #expect(!r.lowercased().contains("hundred"), "got \(r)")
        #expect(!r.lowercased().contains("twenty"), "got \(r)")
        // Bare "number two" still 2, not 200
        #expect(SpokenListITN.apply("number two eggs").contains("2. "))
        var c = 1
        _ = SpokenListITN.apply("number two hundred", counter: &c)
        #expect(c == 201)
    }
}
