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

    /// Press Escape (0x35 / kVK_Escape). Posted at annotated tap so the session
    /// event tap that cancels on physical ESC does not re-intercept.
    func pressEscape() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let escapeKey: CGKeyCode = 0x35 // kVK_Escape
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKey, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// System undo via ⌘Z (0x06 / kVK_ANSI_Z). Does not touch Chirp edit stack.
    func pressUndo() {
        postCommandKey(0x06) // kVK_ANSI_Z
    }

    /// System redo via ⌘⇧Z (0x06 / kVK_ANSI_Z). Does not touch Chirp edit stack.
    func pressRedo() {
        postCommandShiftKey(0x06) // kVK_ANSI_Z
    }

    /// Press Forward Delete (0x75 / kVK_ForwardDelete). Does not touch Chirp buffer.
    func pressForwardDelete() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let forwardDelete: CGKeyCode = 0x75 // kVK_ForwardDelete
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: forwardDelete, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: forwardDelete, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Select one word via ⇧⌥← / ⇧⌥→ (0x7B / 0x7C).
    func selectWord(direction: MoveDirection) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let arrow: CGKeyCode = direction == .left ? 0x7B : 0x7C // kVK_LeftArrow / kVK_RightArrow
        let flags: CGEventFlags = [.maskShift, .maskAlternate]
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Delete one word: selectWord then backspace (deletes selection).
    func deleteWord(direction: MoveDirection) {
        selectWord(direction: direction)
        deleteBackward(count: 1)
    }

    /// Select characters backward by holding shift and pressing left arrow (0x7B).
    func selectBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let leftArrow: CGKeyCode = 0x7B // kVK_LeftArrow
        for _ in 0..<count {
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true) {
                keyDown.flags = .maskShift
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false) {
                keyUp.flags = .maskShift
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Select all via ⌘A.
    func selectAll() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let aKey: CGKeyCode = 0x00 // kVK_ANSI_A
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor one word via ⌥← / ⌥→ (0x7B / 0x7C).
    func moveWord(direction: MoveDirection) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let arrow: CGKeyCode = direction == .left ? 0x7B : 0x7C // kVK_LeftArrow / kVK_RightArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true) {
            keyDown.flags = .maskAlternate
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false) {
            keyUp.flags = .maskAlternate
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor one line via plain ↑ / ↓ (0x7E / 0x7D — kVK_UpArrow / kVK_DownArrow).
    func moveLine(direction: MoveDirection) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let arrow: CGKeyCode = direction == .up ? 0x7E : 0x7D // kVK_UpArrow / kVK_DownArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor to line start via ⌘←.
    func moveToLineStart() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let leftArrow: CGKeyCode = 0x7B // kVK_LeftArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor to line end via ⌘→.
    func moveToLineEnd() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let rightArrow: CGKeyCode = 0x7C // kVK_RightArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor to document start via ⌘↑ (0x7E — kVK_UpArrow).
    func moveToDocumentStart() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let upArrow: CGKeyCode = 0x7E // kVK_UpArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: upArrow, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: upArrow, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor to document end via ⌘↓ (0x7D — kVK_DownArrow).
    func moveToDocumentEnd() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let downArrow: CGKeyCode = 0x7D // kVK_DownArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: downArrow, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: downArrow, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Scroll one page via Page Up / Page Down (0x74 / 0x79 — kVK_PageUp / kVK_PageDown).
    /// Uses `.up` → Page Up, `.down` → Page Down (left/right ignored as up/down only).
    func scrollPage(direction: MoveDirection) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key: CGKeyCode = direction == .up ? 0x74 : 0x79 // kVK_PageUp / kVK_PageDown
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Move cursor left `count` times via plain ← (no shift, no option).
    func moveBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let leftArrow: CGKeyCode = 0x7B // kVK_LeftArrow
        for _ in 0..<count {
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true) {
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Move cursor right `count` times via plain → (no shift, no option).
    func moveForward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let rightArrow: CGKeyCode = 0x7C // kVK_RightArrow
        for _ in 0..<count {
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: true) {
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func clipboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Paste via ⌘V so the target app's native paste path runs.
    func pasteFromClipboard() {
        postCommandKey(0x09) // kVK_ANSI_V
    }

    /// Apply bold / italic / underline via ⌘B (0x0B) / ⌘I (0x22) / ⌘U (0x20).
    func applyFormat(_ style: TextFormatStyle) {
        let key: CGKeyCode
        switch style {
        case .bold: key = 0x0B // kVK_ANSI_B
        case .italic: key = 0x22 // kVK_ANSI_I
        case .underline: key = 0x20 // kVK_ANSI_U
        }
        postCommandKey(key)
    }

    /// Collapse selection to its end via right-arrow (0x7C) without shift.
    /// Standard macOS text behavior: unshifted right-arrow leaves the caret
    /// at the trailing edge of the former selection.
    func clearSelection() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let rightArrow: CGKeyCode = 0x7C // kVK_RightArrow
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: true) {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: false) {
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Cut selection via ⌘X (0x07 / kVK_ANSI_X).
    func cutSelection() {
        postCommandKey(0x07) // kVK_ANSI_X
    }

    /// Post a ⌘+key keystroke (down then up with command flag).
    private func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Post a ⌘⇧+key keystroke (down then up with command+shift flags).
    private func postCommandShiftKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
