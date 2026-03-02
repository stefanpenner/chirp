// AudioRecorder.swift — Captures microphone audio as 16 kHz mono Float arrays.
// Wraps AVAudioEngine with sample-rate conversion. Conforms to AudioRecording.
// Used by AppState.startRecording(); the onSamples callback delivers chunks
// to the transcriber on each audio buffer.
//
// The engine is prepared once (via prepare()) and kept alive between recordings.
// startRecording/stopRecording only install/remove the tap — near-instant.

@preconcurrency import AVFoundation
import CoreAudio
import os

@MainActor
final class AudioRecorder: AudioRecording {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private let sampleRate: Double = 16000
    private var configObserver: (any NSObjectProtocol)?
    private var parkTimer: Timer?
    private let audioDucker = AudioDucker()
    /// Suppresses config-change notifications fired as a side-effect of prepare().
    /// VP and engine.prepare() can each fire one; a boolean only catches one of them.
    private var suppressConfigChanges = false
    /// True while a tap is installed and audio is flowing. Prevents config-change
    /// notifications from tearing down the engine mid-recording.
    private var isRecordingActive = false
    /// Set when a config change fires during recording. The full tearDown+prepare
    /// is deferred to stopRecording.
    private var configChangeDeferred = false

    /// The device ID to use for recording, or nil for the system default.
    var selectedDeviceID: AudioDeviceID?

    /// When true, enables Apple Voice Processing IO for noise suppression, AEC, and AGC.
    var voiceProcessingEnabled: Bool = true

    func requestMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Creates the AVAudioEngine and converter without starting I/O.
    /// Call once when the app is ready (e.g. after model loads).
    /// Subsequent calls are no-ops if the engine already exists.
    func prepare() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()

        // Set the input device before accessing inputNode's format.
        // Accessing inputNode implicitly opens the default device, so we
        // must redirect to the selected device first via its AudioUnit.
        if let deviceID = selectedDeviceID {
            let inputNode = engine.inputNode
            var devID = deviceID
            let status = AudioUnitSetProperty(
                inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                NSLog("Chirp: Failed to set input device %u (status %d)", deviceID, status)
            }
        }

        let inputNode = engine.inputNode

        // Voice Processing creates an aggregate device coupling input+output
        // for AEC. On Bluetooth, this fights the device's own echo/volume
        // management via AVRCP, causing output volume to jump erratically.
        if voiceProcessingEnabled && !isBluetoothInput() {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                NSLog("Chirp: Failed to enable voice processing: %@", error.localizedDescription)
            }
        }

        let inFormat = inputNode.outputFormat(forBus: 0)

        guard let tgtFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("Chirp: Failed to create target audio format")
            return
        }

        // VP may expose multiple internal channels (e.g. 9 ch on some Macs).
        // The converter source must be mono — we extract channel 0 in the tap block.
        let convSource: AVAudioFormat
        if inFormat.channelCount > 1, let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
            channels: 1, interleaved: false
        ) {
            convSource = mono
        } else {
            convSource = inFormat
        }

        guard let conv = AVAudioConverter(from: convSource, to: tgtFormat) else {
            NSLog("Chirp: Failed to create audio converter (%@ → %@)", convSource.description, tgtFormat.description)
            return
        }

        // Preallocate resources without starting I/O. The engine will be
        // started on-demand in startRecording(). Starting it eagerly here
        // activates the microphone and shows the orange indicator. (#6)
        engine.prepare()

        self.audioEngine = engine
        self.converter = conv
        self.targetFormat = tgtFormat
        self.inputFormat = inFormat

        // Re-prepare on audio device changes (e.g. headphones plugged in).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // During recording, don't tear down — just rebuild the converter
                // and defer the full rebuild to after recording stops.
                if self.isRecordingActive || self.suppressConfigChanges {
                    self.rebuildConverter()
                    if self.isRecordingActive { self.configChangeDeferred = true }
                    return
                }
                self.tearDown()
                // Don't eagerly re-prepare — VP's aggregate device dims
                // system audio. The engine will be lazily prepared in
                // startRecording() instead.
            }
        }

        // VP's setVoiceProcessingEnabled and engine.prepare() can each fire a
        // config-change notification. Suppress all of them until the next run
        // loop iteration, when we clear the flag.
        suppressConfigChanges = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressConfigChanges = false
        }
    }

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        cancelPark()

        if audioEngine == nil { prepare() }

        // Try to start the engine. If it fails (e.g. VP format mismatch after
        // config change), rebuild from scratch. If that also fails, retry
        // without voice processing as a last resort.
        if let engine = audioEngine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Chirp: Engine start failed (%@), rebuilding", error.localizedDescription)
                tearDown()
                prepare()
                if let engine = audioEngine, !engine.isRunning {
                    do {
                        try engine.start()
                    } catch {
                        NSLog("Chirp: Engine start failed after rebuild (%@), retrying without VP", error.localizedDescription)
                        tearDown()
                        let savedVP = voiceProcessingEnabled
                        voiceProcessingEnabled = false
                        prepare()
                        voiceProcessingEnabled = savedVP
                        if let engine = audioEngine, !engine.isRunning {
                            do { try engine.start() } catch {
                                NSLog("Chirp: Engine start failed without VP: %@", error.localizedDescription)
                                return
                            }
                        }
                    }
                }
            }
        }

        guard let engine = audioEngine, engine.isRunning else { return }

        // Re-read the format from the running engine — config changes since
        // prepare() may have changed VP or the audio device.
        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
        if currentFormat != inputFormat {
            rebuildConverter()
        }

        guard let converter, let targetFormat, let inputFormat else { return }

        // Validate format: degenerate formats (0 channels, 0 sample rate) cause
        // installTap to throw an unrecoverable NSException.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            Log.audio.error("Invalid audio format (\(inputFormat)); rebuilding engine")
            tearDown()
            prepare()
            return
        }

        let tapBlock = Self.makeTapBlock(
            converter: converter,
            targetFormat: targetFormat,
            inputSampleRate: inputFormat.sampleRate,
            outputRate: sampleRate,
            onSamples: onSamples
        )

        // Defensive: remove any stale tap before installing a new one.
        // installTap throws an unrecoverable NSException if a tap already exists.
        engine.inputNode.removeTap(onBus: 0)
        // Pass nil format — letting AVFAudio use the node's native output format
        // avoids the assertion "format.sampleRate == inputHWFormat.sampleRate"
        // when VP's output sample rate differs from hardware input sample rate.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tapBlock)
        isRecordingActive = true
        audioDucker.duck()
    }

    // nonisolated: prevents @MainActor executor checks from leaking
    // into the returned closure, which runs on AVAudioEngine's I/O thread.
    nonisolated static func makeTapBlock(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        inputSampleRate: Double,
        outputRate: Double,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * outputRate / inputSampleRate
            )
            guard frameCount > 0 else { return }

            // VP may expose multiple internal channels. Extract channel 0
            // (the voice channel) into a mono buffer for conversion.
            let source: AVAudioPCMBuffer
            if buffer.format.channelCount > 1 {
                guard let monoFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                    channels: 1, interleaved: false
                ),
                let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buffer.frameLength),
                let src = buffer.floatChannelData?[0],
                let dst = mono.floatChannelData?[0] else { return }
                mono.frameLength = buffer.frameLength
                memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                source = mono
            } else {
                source = buffer
            }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return source
            }

            if error != nil { return }

            guard let channelData = convertedBuffer.floatChannelData else { return }
            let count = Int(convertedBuffer.frameLength)
            let chunk = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: count
            ))
            onSamples(chunk)
        }
    }

    func stopRecording() {
        isRecordingActive = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioDucker.unduck()
        // Apply deferred config change now that the tap is removed.
        if configChangeDeferred {
            configChangeDeferred = false
            tearDown()
        }
        schedulePark()
    }

    private func schedulePark() {
        parkTimer?.invalidate()
        parkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.parkEngine()
            }
        }
    }

    private func cancelPark() {
        parkTimer?.invalidate()
        parkTimer = nil
    }

    private func parkEngine() {
        parkTimer = nil
        // Full teardown so VP's aggregate device is destroyed and system
        // audio output returns to normal volume. The engine is lazily
        // re-prepared in startRecording().
        tearDown()
    }

    /// Re-reads the input format and rebuilds the converter without tearing down the engine.
    /// Used after VP config changes where the engine is still valid.
    private func rebuildConverter() {
        guard let engine = audioEngine, let tgtFormat = targetFormat else { return }
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        let convSource: AVAudioFormat
        if newFormat.channelCount > 1, let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: newFormat.sampleRate,
            channels: 1, interleaved: false
        ) {
            convSource = mono
        } else {
            convSource = newFormat
        }
        guard let conv = AVAudioConverter(from: convSource, to: tgtFormat) else {
            NSLog("Chirp: Failed to rebuild converter after config change (%@ → %@)", convSource.description, tgtFormat.description)
            return
        }
        self.converter = conv
        self.inputFormat = newFormat
    }

    /// Returns true if the active input device uses Bluetooth transport.
    private func isBluetoothInput() -> Bool {
        let deviceID: AudioDeviceID
        if let selected = selectedDeviceID {
            deviceID = selected
        } else {
            // Query the system default input device.
            var defaultID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, &defaultID
            )
            guard status == noErr, defaultID != kAudioObjectUnknown else { return false }
            deviceID = defaultID
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    func selectInputDevice(_ deviceID: AudioDeviceID?) {
        selectedDeviceID = deviceID
        tearDown()
        // Engine is lazily prepared in startRecording().
    }

    private func tearDown() {
        cancelPark()
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        isRecordingActive = false
        configChangeDeferred = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        targetFormat = nil
        inputFormat = nil
    }
}
