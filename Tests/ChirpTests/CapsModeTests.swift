// CapsModeTests.swift — Pure caps transforms (dual of specs/CapsMode.tla).

import Testing
@testable import Chirp

@Suite("CapsTransform")
struct CapsModeTests {

    @Test("normal mode is identity")
    func normalIdentity() {
        #expect(CapsTransform.apply("Hello World", mode: .normal) == "Hello World")
    }

    @Test("noCaps lowercases")
    func noCaps() {
        #expect(CapsTransform.apply("Hello World", mode: .noCaps) == "hello world")
    }

    @Test("allCaps uppercases")
    func allCaps() {
        #expect(CapsTransform.apply("Hello World", mode: .allCaps) == "HELLO WORLD")
    }

    @Test("capsOn title-cases words")
    func capsOn() {
        #expect(CapsTransform.apply("hello world", mode: .capsOn) == "Hello World")
        #expect(CapsTransform.apply("hello\nworld", mode: .capsOn) == "Hello\nWorld")
    }

    @Test("capitalizeWord one-shot")
    func capitalizeWord() {
        #expect(CapsTransform.capitalizeWord("hello") == "Hello")
        #expect(CapsTransform.capitalizeWord("HELLO") == "Hello")
        #expect(CapsTransform.capitalizeWord("") == "")
    }

    @Test("capitalizeFirstWord only first word (cap next)")
    func capitalizeFirstWord() {
        #expect(CapsTransform.capitalizeFirstWord("hello world") == "Hello world")
        #expect(CapsTransform.capitalizeFirstWord("HELLO world") == "Hello world")
        #expect(CapsTransform.capitalizeFirstWord("  hello") == "  Hello")
        #expect(CapsTransform.capitalizeFirstWord("hello") == "Hello")
        #expect(CapsTransform.capitalizeFirstWord("") == "")
    }

    @Test("empty text stays empty under any mode")
    func empty() {
        #expect(CapsTransform.apply("", mode: .allCaps).isEmpty)
        #expect(CapsTransform.apply("", mode: .capsOn).isEmpty)
    }

    @Test("overlay labels only for non-normal modes")
    func overlayLabels() {
        #expect(CapsMode.normal.overlayLabel == nil)
        #expect(CapsMode.noCaps.overlayLabel == "no caps")
        #expect(CapsMode.allCaps.overlayLabel == "ALL CAPS")
        #expect(CapsMode.capsOn.overlayLabel == "Title Case")
    }

    @Test("sentenceCase lowers and recaps after periods")
    func sentenceCase() {
        #expect(CapsTransform.sentenceCase("HELLO WORLD") == "Hello world")
        #expect(CapsTransform.sentenceCase("HELLO. WORLD") == "Hello. World")
        #expect(CapsTransform.sentenceCase("") == "")
    }

    @Test("stripLeadingSpace removes only leading whitespace")
    func stripLeadingSpace() {
        #expect(CapsTransform.stripLeadingSpace(" world") == "world")
        #expect(CapsTransform.stripLeadingSpace("world") == "world")
        #expect(CapsTransform.stripLeadingSpace("  a b") == "a b")
    }
}
