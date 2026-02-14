import Carbon
import HotKey

@MainActor
final class HotkeyManager {
    private let hotKey: HotKey
    private let action: () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        self.hotKey = HotKey(key: .space, modifiers: [.option])
        self.hotKey.keyDownHandler = { [action] in
            action()
        }
    }
}
