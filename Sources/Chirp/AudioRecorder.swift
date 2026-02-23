// AudioRecorder.swift — Captures microphone audio as 16 kHz mono Float arrays.
// Wraps AVAudioEngine with sample-rate conversion. Conforms to AudioRecording.
// Used by AppState.startRecording(); the onSamples callback delivers chunks
// to the transcriber on each audio buffer.
//
// The engine is prepared once (via prepare()) and kept alive between recordings.
// startRecording/stopRecording only install/remove the tap — near-instant.

@preconcurrency import AVFoundation
import Accelerate
import CoreAudio

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
    /// Suppresses the next config-change notification (fired by setVoiceProcessingEnabled).
    private var ignoreNextConfigChange = false

    /// The device ID to use for recording, or nil for the system default.
    var selectedDeviceID: AudioDeviceID?

    /// When true, enables Apple Voice Processing IO for noise suppression, AEC, and AGC.
    var voiceProcessingEnabled: Bool = true

    /// RMS threshold below which audio buffers are dropped as silence.
    /// Set to 0 to disable the gate.
    var silenceGateThreshold: Float = 0.007

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

        if voiceProcessingEnabled {
            do {
                // setVoiceProcessingEnabled fires AVAudioEngineConfigurationChange;
                // suppress that to avoid a tearDown/prepare cycle that crashes.
                ignoreNextConfigChange = true
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                ignoreNextConfigChange = false
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
                if self.ignoreNextConfigChange {
                    self.ignoreNextConfigChange = false
                    // VP-triggered config change: the engine is valid but the
                    // format may have updated. Re-read and rebuild the converter.
                    self.rebuildConverter()
                    return
                }
                self.tearDown()
                self.prepare()
            }
        }
    }

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        cancelPark()

        if audioEngine == nil { prepare() }

        guard let engine = audioEngine,
              let converter,
              let targetFormat,
              let inputFormat else { return }

        let inputSampleRate = inputFormat.sampleRate
        let rate = sampleRate

        let tapBlock = Self.makeTapBlock(
            converter: converter,
            targetFormat: targetFormat,
            inputSampleRate: inputSampleRate,
            outputRate: rate,
            silenceGateThreshold: silenceGateThreshold,
            onSamples: onSamples
        )
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Chirp: Failed to restart parked engine: %@", error.localizedDescription)
                return
            }
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tapBlock)

        audioDucker.duck()
    }

    // nonisolated: prevents @MainActor executor checks from leaking
    // into the returned closure, which runs on AVAudioEngine's I/O thread.
    nonisolated private static func makeTapBlock(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        inputSampleRate: Double,
        outputRate: Double,
        silenceGateThreshold: Float,
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

            // Energy gate: drop buffers below RMS threshold
            if silenceGateThreshold > 0 {
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(count))
                if rms < silenceGateThreshold { return }
            }

            let chunk = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: count
            ))
            onSamples(chunk)
        }
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioDucker.unduck()
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
        audioEngine?.stop()
        audioEngine?.prepare()
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

    func selectInputDevice(_ deviceID: AudioDeviceID?) {
        selectedDeviceID = deviceID
        tearDown()
        prepare()
    }

    private func tearDown() {
        cancelPark()
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        targetFormat = nil
        inputFormat = nil
    }
}
