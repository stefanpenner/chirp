// TextInserter.swift — Simulates keyboard input via CGEvent.
// Conforms to TextInserting protocol. Used by AppState to type
// transcribed text into whichever app has focus.

import AppKit
@preconcurrency import ApplicationServices

/// One step when typing text that may contain newlines.
enum TextInsertionStep: Equatable, Sendable {
    case text(String)
    case returnKey
}

@MainActor
final class TextInserter: TextInserting {

    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("Accessibility permission not granted. Text insertion will not work.")
        }
    }

    /// Plan keystrokes for `text`. Newlines → Return; pure and dual-tested.
    static func steps(for text: String) -> [TextInsertionStep] {
        guard !text.isEmpty else { return [] }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        var steps: [TextInsertionStep] = []
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                steps.append(.text(String(part)))
            }
            if index < parts.count - 1 {
                steps.append(.returnKey)
            }
        }
        return steps
    }

    /// Type text by posting Unicode keyboard events.
    /// Newlines become Return key presses (0x24) so spoken "new line" works
    /// in apps that ignore Unicode U+000A from keyboardSetUnicodeString.
    /// CGEventKeyboardSetUnicodeString supports up to 20 UniChars per event,
    /// so longer strings are split into chunks.
    func typeText(_ text: String) {
        for step in Self.steps(for: text) {
            switch step {
            case .text(let s): typeUnicode(s)
            case .returnKey: pressReturn()
            }
        }
    }

    private func typeUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 20) {
            let end = min(start + 20, utf16.count)
            let chunk = Array(utf16[start..<end])
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x31, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x31, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    private func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let returnKey: CGKeyCode = 0x24
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Delete characters by posting backspace (0x33) key events.
    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) {
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}
