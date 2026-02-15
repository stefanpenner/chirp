// HotkeyManager.swift — Intercepts the fn/Globe key via CGEvent tap.
// Suppresses the key from reaching the system (no emoji picker),
// and calls onPress/onRelease closures on the main actor.
// Created by AppState.init; lives for the app's lifetime.

import AppKit
@preconcurrency import CoreGraphics

private let kFnKeyCode: UInt16 = 0x3F  // Globe/fn key

@MainActor
final class HotkeyManager {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    /// Tracks fn key state. Accessed from the event tap callback thread
    /// and read from @MainActor context, so marked nonisolated(unsafe).
    nonisolated(unsafe) private var fnDown = false
    nonisolated(unsafe) private static var current: HotkeyManager?

    init(onPress: @escaping @MainActor () -> Void, onRelease: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        HotkeyManager.current = self
        setupEventTap()
    }

    private func setupEventTap() {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
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

                // Suppress fn/Globe keyDown and keyUp (prevents emoji picker)
                if type == .keyDown || type == .keyUp {
                    if keyCode == kFnKeyCode { return nil }
                    return Unmanaged.passRetained(event)
                }

                guard type == .flagsChanged else {
                    return Unmanaged.passRetained(event)
                }

                let pressed = flags.contains(.maskSecondaryFn)

                if pressed && !mgr.fnDown {
                    mgr.fnDown = true
                    Task { @MainActor in mgr.onPress() }
                    return nil
                } else if !pressed && mgr.fnDown {
                    mgr.fnDown = false
                    Task { @MainActor in mgr.onRelease() }
                    return nil
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            NSLog("Chirp: Failed to create event tap — check Accessibility permissions")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        let tap = eventTap
        let source = runLoopSource
        MainActor.assumeIsolated {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        HotkeyManager.current = nil
    }
}
