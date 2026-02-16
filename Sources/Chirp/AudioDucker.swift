// AudioDucker.swift — Lowers system output volume while recording.
// Uses CoreAudio to duck the default output device, then restores
// the original volume when recording ends. AVAudioSession is
// unavailable on macOS, so we manipulate the hardware volume directly.

import CoreAudio

@MainActor
protocol VolumeControl {
    func defaultOutputDevice() -> AudioDeviceID?
    func getVolume(device: AudioDeviceID, channel: UInt32) -> Float32?
    func setVolume(device: AudioDeviceID, channel: UInt32, volume: Float32)
}

@MainActor
struct SystemVolumeControl: VolumeControl {
    func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    func getVolume(device: AudioDeviceID, channel: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: channel
        )

        guard AudioObjectHasProperty(device, &address) else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    func setVolume(device: AudioDeviceID, channel: UInt32, volume: Float32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: channel
        )

        guard AudioObjectHasProperty(device, &address) else { return }

        var vol = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)

        AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
    }
}

@MainActor
final class AudioDucker {
    private var savedVolumes: [(channel: UInt32, volume: Float32)] = []
    private var savedDeviceID: AudioDeviceID?
    private(set) var isDucked = false
    private let volumeControl: any VolumeControl
    static let duckFraction: Float32 = 0.25

    init(volumeControl: any VolumeControl = SystemVolumeControl()) {
        self.volumeControl = volumeControl
    }

    func duck() {
        guard !isDucked else { return }
        guard let deviceID = volumeControl.defaultOutputDevice() else { return }

        savedVolumes = []
        savedDeviceID = deviceID

        // Try master volume first (channel 0)
        if let masterVolume = volumeControl.getVolume(device: deviceID, channel: 0) {
            savedVolumes.append((channel: 0, volume: masterVolume))
            volumeControl.setVolume(device: deviceID, channel: 0, volume: masterVolume * Self.duckFraction)
        } else {
            // Fall back to per-channel volumes (L=1, R=2)
            for channel: UInt32 in 1...2 {
                if let vol = volumeControl.getVolume(device: deviceID, channel: channel) {
                    savedVolumes.append((channel: channel, volume: vol))
                    volumeControl.setVolume(device: deviceID, channel: channel, volume: vol * Self.duckFraction)
                }
            }
        }

        isDucked = !savedVolumes.isEmpty
    }

    func unduck() {
        guard isDucked, let deviceID = savedDeviceID else { return }
        isDucked = false

        for (channel, volume) in savedVolumes {
            volumeControl.setVolume(device: deviceID, channel: channel, volume: volume)
        }
        savedVolumes = []
        savedDeviceID = nil
    }
}
