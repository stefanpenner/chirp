import AppKit
import CoreGraphics

private let kFnKeyCode: UInt16 = 0x3F  // Globe/fn key

@MainActor
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    private var fnDown = false
    nonisolated(unsafe) private static var current: HotkeyManager?

    init(onPress: @escaping @MainActor () -> Void, onRelease: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        HotkeyManager.current = self
        setupEventTap()
    }

    private func setupEventTap() {
        // Intercept flagsChanged, keyDown, and keyUp to fully suppress fn/Globe
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
                // Re-enable tap if system disabled it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let mgr = HotkeyManager.current, let tap = mgr.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }

                guard let mgr = HotkeyManager.current else {
                    return Unmanaged.passRetained(event)
                }

                // Suppress fn/Globe keyDown and keyUp (prevents emoji picker)
                if type == .keyDown || type == .keyUp {
                    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    if keyCode == kFnKeyCode {
                        return nil
                    }
                    return Unmanaged.passRetained(event)
                }

                guard type == .flagsChanged else {
                    return Unmanaged.passRetained(event)
                }

                let pressed = event.flags.contains(.maskSecondaryFn)

                if pressed && !mgr.fnDown {
                    mgr.fnDown = true
                    DispatchQueue.main.async { mgr.onPress() }
                    return nil
                } else if !pressed && mgr.fnDown {
                    mgr.fnDown = false
                    DispatchQueue.main.async { mgr.onRelease() }
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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        HotkeyManager.current = nil
    }
}
