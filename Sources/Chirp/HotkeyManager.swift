import AppKit

@MainActor
final class HotkeyManager {
    private var monitor: Any?
    private var fnDown = false

    init(onPress: @escaping @MainActor () -> Void, onRelease: @escaping @MainActor () -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            let pressed = event.modifierFlags.contains(.function)
            if pressed && !self.fnDown {
                self.fnDown = true
                onPress()
            } else if !pressed && self.fnDown {
                self.fnDown = false
                onRelease()
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
