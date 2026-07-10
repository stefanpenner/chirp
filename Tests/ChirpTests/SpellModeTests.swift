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
}
