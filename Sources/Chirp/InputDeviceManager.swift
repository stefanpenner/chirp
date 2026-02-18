// InputDeviceManager.swift — Enumerates audio input devices via CoreAudio.
// Provides a list of available input devices and listens for hardware changes
// (devices plugged/unplugged). Persists the user's selection by device UID
// (stable across reboots, unlike AudioDeviceID which can change).

import CoreAudio
import Foundation

public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isDefault: Bool
}

@MainActor
@Observable
public final class InputDeviceManager {
    private static let selectedDeviceUIDKey = "selectedInputDeviceUID"

    public var devices: [InputDevice] = []

    /// The UID of the user-selected device, or nil for system default.
    public var selectedDeviceUID: String? {
        didSet {
            if let uid = selectedDeviceUID {
                UserDefaults.standard.set(uid, forKey: Self.selectedDeviceUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedDeviceUIDKey)
            }
        }
    }

    /// The AudioDeviceID for the selected device, or nil to use the system default.
    public var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid })?.id
    }

    // nonisolated(unsafe): written once on MainActor at init, read in deinit.
    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.selectedDeviceUIDKey)
        refresh()
        installDeviceChangeListener()
    }

    deinit {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    public func refresh() {
        let defaultID = Self.defaultInputDeviceID()
        devices = Self.enumerateInputDevices(defaultID: defaultID)

        // If the saved device is no longer present, fall back to default.
        if let uid = selectedDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            selectedDeviceUID = nil
        }
    }

    // MARK: - CoreAudio enumeration

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func enumerateInputDevices(defaultID: AudioDeviceID?) -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard hasInputChannels(deviceID: id) else { return nil }
            guard let name = deviceName(deviceID: id) else { return nil }
            guard let uid = deviceUID(deviceID: id) else { return nil }
            return InputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID)
        }
    }

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let channelCount = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channelCount > 0
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    private static func deviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    // MARK: - Device change listener

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

}
