// AudioRecorder.swift — Captures microphone audio as 16 kHz mono Float arrays.
// Wraps AVAudioEngine with sample-rate conversion. Conforms to AudioRecording.
// Used by AppState.startRecording(); the onSamples callback delivers chunks
// to the transcriber on each audio buffer.
//
// The engine is prepared once (via prepare()) and kept alive between recordings.
// startRecording/stopRecording only install/remove the tap — near-instant.

@preconcurrency import AVFoundation
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

    /// The device ID to use for recording, or nil for the system default.
    var selectedDeviceID: AudioDeviceID?

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

        guard let conv = AVAudioConverter(from: inFormat, to: tgtFormat) else {
            NSLog("Chirp: Failed to create audio converter (%@ → %@)", inFormat.description, tgtFormat.description)
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
                self?.tearDown()
                self?.prepare()
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
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * outputRate / inputSampleRate
            )
            guard frameCount > 0 else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error != nil { return }

            if let channelData = convertedBuffer.floatChannelData {
                let count = Int(convertedBuffer.frameLength)
                let chunk = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: count
                ))
                onSamples(chunk)
            }
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
