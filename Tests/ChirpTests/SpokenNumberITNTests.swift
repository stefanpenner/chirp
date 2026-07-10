// SpokenNumberITNTests.swift — Multi-token spoken cardinal ITN.

import Testing
@testable import Chirp

@Suite("SpokenNumberITN")
struct SpokenNumberITNTests {

    @Test("does not convert bare small units")
    func bareUnitsStay() {
        #expect(SpokenNumberITN.apply("one more thing") == "one more thing")
        #expect(SpokenNumberITN.apply("two birds") == "two birds")
        #expect(SpokenNumberITN.apply("ten items") == "ten items")
    }

    @Test("converts teens and tens compounds")
    func teensAndCompounds() {
        #expect(SpokenNumberITN.apply("I saw fifteen birds") == "I saw 15 birds")
        #expect(SpokenNumberITN.apply("twenty five apples") == "25 apples")
        #expect(SpokenNumberITN.apply("ninety nine") == "99")
        #expect(SpokenNumberITN.apply("twenty") == "20")
    }

    @Test("converts hundreds and thousands")
    func magnitudes() {
        #expect(SpokenNumberITN.apply("one hundred") == "100")
        #expect(SpokenNumberITN.apply("two hundred fifty") == "250")
        #expect(SpokenNumberITN.apply("one hundred and five") == "105")
        #expect(SpokenNumberITN.apply("three thousand") == "3000")
        #expect(SpokenNumberITN.apply("one thousand two hundred") == "1200")
    }

    @Test("converts decimals with point")
    func decimals() {
        #expect(SpokenNumberITN.apply("three point five") == "3.5")
        #expect(SpokenNumberITN.apply("ten point two five") == "10.25")
    }

    @Test("parsePhrase unit tests")
    func parsePhrase() {
        #expect(SpokenNumberITN.parsePhrase(["twenty", "one"]) == 21)
        #expect(SpokenNumberITN.parsePhrase(["one", "hundred"]) == 100)
        #expect(SpokenNumberITN.parsePhrase(["one"]) == 1) // parse ok; apply() refuses convert
        #expect(SpokenNumberITN.parsePhrase(["point", "five"]) == nil)
    }

    @Test("ordinals convert with discourse guards")
    func ordinals() {
        #expect(SpokenNumberITN.formatOrdinal(1) == "1st")
        #expect(SpokenNumberITN.formatOrdinal(2) == "2nd")
        #expect(SpokenNumberITN.formatOrdinal(3) == "3rd")
        #expect(SpokenNumberITN.formatOrdinal(11) == "11th")
        #expect(SpokenNumberITN.formatOrdinal(21) == "21st")
        #expect(SpokenNumberITN.apply("came in first") == "came in 1st")
        #expect(SpokenNumberITN.apply("twenty first birthday") == "21st birthday")
        #expect(SpokenNumberITN.apply("the fifteenth floor") == "the 15th floor")
        // Discourse idioms stay words
        #expect(SpokenNumberITN.apply("first of all") == "first of all")
        #expect(SpokenNumberITN.apply("first class cabin") == "first class cabin")
        #expect(SpokenNumberITN.apply("first time here") == "first time here")
    }
}

@Suite("TextPostProcessor number ITN")
struct TextPostProcessorNumberITNTests {

    @Test("integrates cardinals with dollars and percent")
    func integrated() {
        #expect(TextPostProcessor.process("costs one hundred dollars") == "costs $100")
        #expect(TextPostProcessor.process("about fifty percent done") == "about 50% done")
        #expect(TextPostProcessor.process("one hundred percent ready") == "100% ready")
        // Bare one stays
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
    }

    @Test("meeting times still work after cardinal ITN")
    func timesStillWork() {
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
    }
}
