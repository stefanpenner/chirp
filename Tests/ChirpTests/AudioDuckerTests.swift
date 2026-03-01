import Testing
import CoreAudio
@testable import Chirp

@MainActor
final class MockVolumeControl: VolumeControl {
    var device: AudioDeviceID? = 42
    var bluetoothDevices: Set<AudioDeviceID> = []
    /// Channel → volume. Nil means the channel has no volume control.
    var volumes: [UInt32: Float32] = [0: 0.8]
    var setVolumeCalls: [(device: AudioDeviceID, channel: UInt32, volume: Float32)] = []

    func defaultOutputDevice() -> AudioDeviceID? { device }

    func isBluetooth(device: AudioDeviceID) -> Bool {
        bluetoothDevices.contains(device)
    }

    func getVolume(device: AudioDeviceID, channel: UInt32) -> Float32? {
        volumes[channel]
    }

    func setVolume(device: AudioDeviceID, channel: UInt32, volume: Float32) {
        setVolumeCalls.append((device, channel, volume))
        volumes[channel] = volume
    }
}

@Suite("AudioDucker")
@MainActor
struct AudioDuckerTests {

    // MARK: - duck()

    @Test("duck lowers master volume by duckFraction")
    func duckLowersMasterVolume() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(ducker.isDucked)
        #expect(vc.volumes[0]! == 0.8 * AudioDucker.duckFraction)
    }

    @Test("duck falls back to per-channel when no master volume")
    func duckFallsBackToPerChannel() {
        let vc = MockVolumeControl()
        vc.volumes = [1: 0.6, 2: 0.6]  // No channel 0 (master)
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(ducker.isDucked)
        #expect(vc.volumes[1]! == 0.6 * AudioDucker.duckFraction)
        #expect(vc.volumes[2]! == 0.6 * AudioDucker.duckFraction)
    }

    @Test("duck is idempotent")
    func duckIsIdempotent() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()
        let volumeAfterFirstDuck = vc.volumes[0]!

        ducker.duck()  // second duck should be a no-op

        #expect(vc.volumes[0]! == volumeAfterFirstDuck)
        // Only one setVolume call (from the first duck)
        #expect(vc.setVolumeCalls.count == 1)
    }

    @Test("duck is no-op when no output device")
    func duckNoOpWithoutDevice() {
        let vc = MockVolumeControl()
        vc.device = nil
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(!ducker.isDucked)
        #expect(vc.setVolumeCalls.isEmpty)
    }

    @Test("duck is no-op for Bluetooth devices")
    func duckNoOpForBluetooth() {
        let vc = MockVolumeControl()
        vc.device = 42
        vc.bluetoothDevices = [42]
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(!ducker.isDucked)
        #expect(vc.setVolumeCalls.isEmpty)
        #expect(vc.volumes[0]! == 0.8)
    }

    @Test("duck is no-op when device has no volume control")
    func duckNoOpWithoutVolumeControl() {
        let vc = MockVolumeControl()
        vc.volumes = [:]  // no channels
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(!ducker.isDucked)
        #expect(vc.setVolumeCalls.isEmpty)
    }

    // MARK: - unduck()

    @Test("unduck restores master volume")
    func unduckRestoresMasterVolume() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()
        ducker.unduck()

        #expect(!ducker.isDucked)
        #expect(vc.volumes[0]! == 0.8)
    }

    @Test("unduck restores per-channel volumes")
    func unduckRestoresPerChannelVolumes() {
        let vc = MockVolumeControl()
        vc.volumes = [1: 0.6, 2: 0.9]  // asymmetric L/R
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()
        ducker.unduck()

        #expect(vc.volumes[1]! == 0.6)
        #expect(vc.volumes[2]! == 0.9)
    }

    @Test("unduck without duck is no-op")
    func unduckWithoutDuckIsNoOp() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.unduck()

        #expect(!ducker.isDucked)
        #expect(vc.setVolumeCalls.isEmpty)
        #expect(vc.volumes[0]! == 0.8)
    }

    @Test("unduck is idempotent")
    func unduckIsIdempotent() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()
        ducker.unduck()
        let callCount = vc.setVolumeCalls.count

        ducker.unduck()  // second unduck is a no-op

        #expect(vc.setVolumeCalls.count == callCount)
    }

    // MARK: - Cycles

    @Test("Multiple duck/unduck cycles restore correctly")
    func multipleCyclesRestoreCorrectly() {
        let vc = MockVolumeControl()
        vc.volumes = [0: 0.8]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()
        #expect(vc.volumes[0]! == 0.8 * AudioDucker.duckFraction)

        ducker.unduck()
        #expect(vc.volumes[0]! == 0.8)

        ducker.duck()
        #expect(vc.volumes[0]! == 0.8 * AudioDucker.duckFraction)

        ducker.unduck()
        #expect(vc.volumes[0]! == 0.8)
    }

    @Test("duck targets the correct device ID")
    func duckTargetsCorrectDevice() {
        let vc = MockVolumeControl()
        vc.device = 99
        vc.volumes = [0: 0.5]
        let ducker = AudioDucker(volumeControl: vc)

        ducker.duck()

        #expect(vc.setVolumeCalls.first?.device == 99)

        // Switch default device before unduck — should still restore to device 99
        vc.device = 200
        ducker.unduck()

        #expect(vc.setVolumeCalls.last?.device == 99)
    }
}
