// AudioRecorder.swift — Captures microphone audio as 16 kHz mono Float arrays.
// Wraps AVAudioEngine with sample-rate conversion. Conforms to AudioRecording.
// Used by AppState.startRecording(); the onSamples callback delivers chunks
// to the transcriber on each audio buffer.

@preconcurrency import AVFoundation

@MainActor
final class AudioRecorder: AudioRecording {
    private var audioEngine: AVAudioEngine?
    private let sampleRate: Double = 16000

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("Chirp: Failed to create target audio format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            NSLog("Chirp: Failed to create audio converter (%@ → %@)", inputFormat.description, targetFormat.description)
            return
        }

        let inputSampleRate = inputFormat.sampleRate
        let rate = sampleRate

        // Build the tap block in a nonisolated context so the Swift compiler
        // does not inject @MainActor executor assertions into the closure.
        // The installTap block runs on AVAudioEngine's I/O thread.
        let tapBlock = Self.makeTapBlock(
            converter: converter,
            targetFormat: targetFormat,
            inputSampleRate: inputSampleRate,
            outputRate: rate,
            onSamples: onSamples
        )
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tapBlock)

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            NSLog("Chirp: Failed to start audio engine: %@", error.localizedDescription)
        }
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
        audioEngine?.stop()
        audioEngine = nil
    }
}
