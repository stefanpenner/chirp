// SpellModeTests.swift — Pure spell transforms (dual of specs/SpellMode.tla).

import Testing
@testable import Chirp

@Suite("SpellTransform")
struct SpellModeTests {

    @Test("off mode is identity")
    func offIdentity() {
        #expect(SpellTransform.apply("alpha bravo", mode: .off) == "alpha bravo")
        #expect(SpellTransform.apply("hello world", mode: .off) == "hello world")
    }

    @Test("empty text stays empty")
    func empty() {
        #expect(SpellTransform.apply("", mode: .on).isEmpty)
        #expect(SpellTransform.apply("", mode: .off).isEmpty)
    }

    @Test("spoken letter names pack without spaces")
    func letterNames() {
        #expect(SpellTransform.apply("a b c", mode: .on) == "abc")
        #expect(SpellTransform.apply("A B C", mode: .on) == "abc")
    }

    @Test("NATO alphabet packs without spaces")
    func nato() {
        #expect(SpellTransform.apply("alpha bravo charlie", mode: .on) == "abc")
        #expect(SpellTransform.apply("alfa juliett x-ray zulu", mode: .on) == "ajxz")
        #expect(SpellTransform.apply("xray yankee", mode: .on) == "xy")
    }

    @Test("digits map to numerals")
    func digits() {
        #expect(SpellTransform.apply("one two three", mode: .on) == "123")
        #expect(SpellTransform.apply("zero oh nine", mode: .on) == "009")
    }

    @Test("capital / upper prefixes uppercase the next letter")
    func capitalPrefix() {
        #expect(SpellTransform.apply("capital a bravo", mode: .on) == "Ab")
        #expect(SpellTransform.apply("upper b alpha", mode: .on) == "Ba")
        #expect(SpellTransform.apply("capital charlie", mode: .on) == "C")
    }

    @Test("space and period tokens")
    func spaceAndPeriod() {
        #expect(SpellTransform.apply("alpha space bravo", mode: .on) == "a b")
        #expect(SpellTransform.apply("a space bar b", mode: .on) == "a b")
        #expect(SpellTransform.apply("alpha period bravo", mode: .on) == "a.b")
        #expect(SpellTransform.apply("alpha dot bravo", mode: .on) == "a.b")
    }

    @Test("unknown words kept as-is with spaces")
    func unknownPreserved() {
        #expect(SpellTransform.apply("hello world", mode: .on) == "hello world")
        #expect(SpellTransform.apply("alpha hello bravo", mode: .on) == "a hello b")
        #expect(SpellTransform.apply("the alpha code", mode: .on) == "the a code")
    }

    @Test("overlay label only when on")
    func overlayLabels() {
        #expect(SpellMode.off.overlayLabel == nil)
        #expect(SpellMode.on.overlayLabel == "Spell")
    }

    @Test("full NATO alphabet a-z")
    func fullNato() {
        let spoken = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
            "golf", "hotel", "india", "juliet", "kilo", "lima",
            "mike", "november", "oscar", "papa", "quebec", "romeo",
            "sierra", "tango", "uniform", "victor", "whiskey", "xray",
            "yankee", "zulu",
        ].joined(separator: " ")
        #expect(SpellTransform.apply(spoken, mode: .on) == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test("one-shot spell as packs letters")
    func oneShotPacksLetters() {
        #expect(SpellTransform.oneShot("spell as a b c") == "abc")
        #expect(SpellTransform.oneShot("Spell as A B C") == "abc")
    }

    @Test("one-shot spell as capital john")
    func oneShotCapitalJohn() {
        #expect(SpellTransform.oneShot("spell as capital j o h n") == "John")
    }

    @Test("one-shot nil when not spell as")
    func oneShotNonMatch() {
        #expect(SpellTransform.oneShot("a b c") == nil)
        #expect(SpellTransform.oneShot("spell mode on") == nil)
        #expect(SpellTransform.oneShot("") == nil)
        #expect(SpellTransform.oneShot("spell as") == nil)
        #expect(SpellTransform.oneShot("spell as   ") == nil)
    }

    @Test("packAcronyms joins single-letter runs uppercase")
    func packAcronymsBasic() {
        #expect(SpellTransform.packAcronyms("a p i") == "API")
        #expect(SpellTransform.packAcronyms("u r l") == "URL")
        #expect(SpellTransform.packAcronyms("i d") == "ID")
        #expect(SpellTransform.packAcronyms("A P I") == "API")
        #expect(SpellTransform.packAcronyms("u i") == "UI")
        #expect(SpellTransform.packAcronyms("a i") == "AI")
    }

    @Test("packAcronyms requires 3 letters unless allowlisted pair")
    func packAcronymsMinLength() {
        // Auto-pack only ≥3; "a b" is not an allowlisted pair
        #expect(SpellTransform.packAcronyms("a b") == "a b")
        #expect(SpellTransform.packAcronyms("x y") == "x y")
        // Common 2-letter allowlist
        #expect(SpellTransform.packAcronyms("i d") == "ID")
        #expect(SpellTransform.packAcronyms("o k") == "OK")
        #expect(SpellTransform.packAcronyms("d b") == "DB")
        #expect(SpellTransform.packAcronyms("t v") == "TV")
        // 3+ still packs
        #expect(SpellTransform.packAcronyms("a p i") == "API")
    }

    @Test("packAcronyms preserves surrounding words and trailing punct")
    func packAcronymsContext() {
        #expect(SpellTransform.packAcronyms("call the a p i please") == "call the API please")
        #expect(SpellTransform.packAcronyms("open the u r l now") == "open the URL now")
        #expect(SpellTransform.packAcronyms("a p i.") == "API.")
        #expect(SpellTransform.packAcronyms("use the a p i.") == "use the API.")
        #expect(SpellTransform.packAcronyms("my i d card") == "my ID card")
        #expect(SpellTransform.packAcronyms("see a b later") == "see a b later")
    }

    @Test("packAcronyms leaves bare I/a, multi-letter, and NATO alone")
    func packAcronymsNoFalsePack() {
        #expect(SpellTransform.packAcronyms("I am fine") == "I am fine")
        #expect(SpellTransform.packAcronyms("a") == "a")
        #expect(SpellTransform.packAcronyms("I") == "I")
        #expect(SpellTransform.packAcronyms("alpha bravo") == "alpha bravo")
        #expect(SpellTransform.packAcronyms("hello world") == "hello world")
        #expect(SpellTransform.packAcronyms("") == "")
    }

    @Test("packAcronyms preserves newlines between paragraphs")
    func packAcronymsPreservesNewlines() {
        #expect(SpellTransform.packAcronyms("Para one\n\nPara two") == "Para one\n\nPara two")
        #expect(SpellTransform.packAcronyms("use a p i\nnext line") == "use API\nnext line")
    }
}
