// HotkeyManager.swift — Intercepts the configured hotkey via CGEvent tap.
// Suppresses the key from reaching the system (no emoji picker for fn),
// and calls onPress/onRelease closures on the main actor.
// Created by AppState.init; lives for the app's lifetime.

import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

// MARK: - HotkeyConfig

public struct HotkeyConfig: Equatable, Sendable {
    public let keyCode: UInt16
    /// Whether this is a modifier-only key (detected via flagsChanged) vs a regular key.
    public let isModifier: Bool
    /// The CGEventFlags mask to check for modifier keys (e.g., .maskSecondaryFn).
    /// Only used when isModifier is true.
    public let modifierMask: CGEventFlags?
    /// For non-modifier keys: additional modifiers required (e.g., ⌘⇧ for ⌘⇧R).
    public let requiredModifiers: CGEventFlags
    /// Human-readable label for UI display.
    public let label: String

    public static let fn = HotkeyConfig(
        keyCode: 0x3F, isModifier: true,
        modifierMask: .maskSecondaryFn, requiredModifiers: [],
        label: "fn"
    )

    // MARK: Label helpers

    static func buildLabel(keyCode: UInt16, isModifier: Bool, modifiers: CGEventFlags = []) -> String {
        if isModifier { return modifierKeyLabel(keyCode) }
        var s = ""
        if modifiers.contains(.maskControl) { s += "⌃" }
        if modifiers.contains(.maskAlternate) { s += "⌥" }
        if modifiers.contains(.maskShift) { s += "⇧" }
        if modifiers.contains(.maskCommand) { s += "⌘" }
        s += regularKeyLabel(keyCode)
        return s
    }

    static func modifierKeyLabel(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0x37: return "Left ⌘"
        case 0x36: return "Right ⌘"
        case 0x38: return "Left ⇧"
        case 0x3C: return "Right ⇧"
        case 0x3A: return "Left ⌥"
        case 0x3D: return "Right ⌥"
        case 0x3B: return "Left ⌃"
        case 0x3E: return "Right ⌃"
        case 0x3F: return "fn"
        default: return String(format: "Key 0x%02X", keyCode)
        }
    }

    private static func regularKeyLabel(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x16: return "6"
        case 0x17: return "5"
        case 0x18: return "="
        case 0x19: return "9"
        case 0x1A: return "7"
        case 0x1B: return "-"
        case 0x1C: return "8"
        case 0x1D: return "0"
        case 0x1E: return "]"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x21: return "["
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x27: return "'"
        case 0x28: return "K"
        case 0x29: return ";"
        case 0x2A: return "\\"
        case 0x2B: return ","
        case 0x2C: return "/"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x2F: return "."
        case 0x32: return "`"
        case 0x24: return "Return"
        case 0x30: return "Tab"
        case 0x31: return "Space"
        case 0x33: return "Delete"
        case 0x35: return "Escape"
        case 0x75: return "⌦"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default: return String(format: "0x%02X", keyCode)
        }
    }

    static func modifierMaskForKeyCode(_ keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 0x37, 0x36: return .maskCommand
        case 0x38, 0x3C: return .maskShift
        case 0x3A, 0x3D: return .maskAlternate
        case 0x3B, 0x3E: return .maskControl
        case 0x3F: return .maskSecondaryFn
        default: return nil
        }
    }

    static func nsModsToCGFlags(_ mods: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags = CGEventFlags()
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    // MARK: Persistence

    private static let defaultsKeyCode = "hotkeyKeyCode"
    private static let defaultsIsModifier = "hotkeyIsModifier"
    private static let defaultsModifierMask = "hotkeyModifierMask"
    private static let defaultsRequiredModifiers = "hotkeyRequiredModifiers"
    private static let defaultsLabel = "hotkeyLabel"

    public static var saved: HotkeyConfig {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKeyCode) != nil else {
                return .fn
            }
            let keyCode = UInt16(UserDefaults.standard.integer(forKey: defaultsKeyCode))
            let isModifier = UserDefaults.standard.bool(forKey: defaultsIsModifier)
            let maskRaw = UserDefaults.standard.integer(forKey: defaultsModifierMask)
            let reqRaw = UserDefaults.standard.integer(forKey: defaultsRequiredModifiers)
            let label = UserDefaults.standard.string(forKey: defaultsLabel) ?? "fn"
            let mask: CGEventFlags? = isModifier ? CGEventFlags(rawValue: UInt64(maskRaw)) : nil
            let req = CGEventFlags(rawValue: UInt64(reqRaw))
            return HotkeyConfig(
                keyCode: keyCode, isModifier: isModifier,
                modifierMask: mask, requiredModifiers: req, label: label
            )
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: defaultsKeyCode)
            UserDefaults.standard.set(newValue.isModifier, forKey: defaultsIsModifier)
            if let mask = newValue.modifierMask {
                UserDefaults.standard.set(Int(mask.rawValue), forKey: defaultsModifierMask)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsModifierMask)
            }
            UserDefaults.standard.set(Int(newValue.requiredModifiers.rawValue), forKey: defaultsRequiredModifiers)
            UserDefaults.standard.set(newValue.label, forKey: defaultsLabel)
        }
    }
}

// MARK: - HotkeyManager

@MainActor
final class HotkeyManager {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var config: HotkeyConfig
    nonisolated(unsafe) private var accessibilityPoller: Task<Void, Never>?
    // These are read from the CGEvent tap C callback which has no Swift Task
    // context. The closures themselves use MainActor.assumeIsolated to safely
    // hop into the main actor. Since the type is @Sendable () -> Void (already
    // Sendable), nonisolated(unsafe) is not required.
    private let onPress: @Sendable () -> Void
    private let onRelease: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

    /// Tracks hotkey state. Accessed from the event tap callback thread
    /// and read from @MainActor context, so marked nonisolated(unsafe).
    nonisolated(unsafe) private var fnDown = false

    /// True while a recording session is active (recording or transcribing).
    /// Checked by the event tap to decide whether ESC should be intercepted.
    nonisolated(unsafe) var sessionActive = false

    /// When true, the configured hotkey is suppressed but callbacks are not fired.
    /// Used while the hotkey recorder dialog is open to prevent the hotkey from
    /// triggering the system action (e.g., emoji picker for fn) without starting
    /// a recording session.
    nonisolated(unsafe) var suppressOnly = false

    nonisolated(unsafe) private static var current: HotkeyManager?

    init(
        config: HotkeyConfig = .saved,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.config = config
        // Wrap @MainActor closures so they can be called safely from
        // non-Task contexts (the CGEvent tap C callback).
        self.onPress = { MainActor.assumeIsolated { onPress() } }
        self.onRelease = { MainActor.assumeIsolated { onRelease() } }
        self.onCancel = { MainActor.assumeIsolated { onCancel() } }
        HotkeyManager.current = self
        setupEventTap()
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        accessibilityPoller?.cancel()
        accessibilityPoller = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        fnDown = false

        config = newConfig
        HotkeyConfig.saved = newConfig
        setupEventTap()
    }

    func suspendTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func resumeTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func setupEventTap() {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << 14)  // NX_SYSDEFINED — system-defined events (emoji picker trigger)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let mgr = HotkeyManager.current, let tap = mgr.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }

                guard let mgr = HotkeyManager.current else {
                    return Unmanaged.passRetained(event)
                }

                let flags = event.flags
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let cfg = mgr.config

                // --- NX_SYSDEFINED (type 14) ---
                // System-defined events include the fn/globe emoji picker trigger.
                // Suppress when our fn hotkey is active or in suppress-only mode
                // to prevent the emoji picker from opening.
                if type.rawValue == 14 {
                    if cfg.keyCode == 0x3F && (mgr.fnDown || mgr.suppressOnly) {
                        return nil
                    }
                    return Unmanaged.passRetained(event)
                }

                // --- keyDown / keyUp ---
                if type == .keyDown || type == .keyUp {
                    // ESC (0x35) cancels the active session
                    if type == .keyDown && keyCode == 0x35 && mgr.sessionActive {
                        DispatchQueue.main.async { mgr.onCancel() }
                        return nil
                    }

                    if keyCode == cfg.keyCode {
                        if cfg.isModifier {
                            // Modifier keys: suppress keyDown/keyUp (handled via flagsChanged)
                            return nil
                        }
                        // Non-modifier: check required modifiers on keyDown
                        if type == .keyDown {
                            let currentMods = flags.intersection(
                                CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl])
                            )
                            if currentMods == cfg.requiredModifiers && !mgr.fnDown {
                                mgr.fnDown = true
                                if !mgr.suppressOnly {
                                    DispatchQueue.main.async { mgr.onPress() }
                                }
                                return nil
                            }
                            // Modifiers don't match — pass through
                            return Unmanaged.passRetained(event)
                        }
                        if type == .keyUp && mgr.fnDown {
                            mgr.fnDown = false
                            if !mgr.suppressOnly {
                                DispatchQueue.main.async { mgr.onRelease() }
                            }
                            return nil
                        }
                    }

                    return Unmanaged.passRetained(event)
                }

                // --- flagsChanged ---
                guard type == .flagsChanged else {
                    return Unmanaged.passRetained(event)
                }

                // For modifier keys, detect via flagsChanged.
                // Check keyCode too — e.g. Left Option and Right Option
                // both set .maskAlternate, so we need to distinguish them.
                if cfg.isModifier, let modifierMask = cfg.modifierMask, keyCode == cfg.keyCode {
                    let pressed = flags.contains(modifierMask)

                    if pressed && !mgr.fnDown {
                        mgr.fnDown = true
                        if !mgr.suppressOnly {
                            DispatchQueue.main.async { mgr.onPress() }
                        }
                        return nil
                    } else if !pressed && mgr.fnDown {
                        mgr.fnDown = false
                        if !mgr.suppressOnly {
                            DispatchQueue.main.async { mgr.onRelease() }
                        }
                        return nil
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            Log.general.error("Failed to create event tap — check Accessibility permissions")
            if accessibilityPoller == nil {
                startAccessibilityPoller()
            }
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        accessibilityPoller?.cancel()
        accessibilityPoller = nil
    }

    private func startAccessibilityPoller() {
        accessibilityPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard AXIsProcessTrusted() else { continue }
                self.setupEventTap()
                break
            }
        }
    }

    deinit {
        accessibilityPoller?.cancel()
        let tap = eventTap
        let source = runLoopSource
        MainActor.assumeIsolated {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        HotkeyManager.current = nil
    }
}
