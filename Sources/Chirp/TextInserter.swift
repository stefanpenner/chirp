import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class TextInserter: TextInserting {
    private var savedClipboard: String?

    func saveClipboard() {
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    func restoreClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let saved = savedClipboard {
            pasteboard.setString(saved, forType: .string)
        }
        savedClipboard = nil
    }

    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("Accessibility permission not granted. Text insertion will not work.")
        }
    }

    /// Type text by simulating keyboard input. No clipboard involvement.
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        // CGEventKeyboardSetUnicodeString handles up to 20 UniChars per event
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

    /// Delete characters by sending backspace key events.
    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            // 0x33 = backspace/delete virtualKey
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) {
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}
