@preconcurrency import AVFoundation

@MainActor
final class AudioRecorder: AudioRecording {
    private var audioEngine: AVAudioEngine?
    private let sampleRate: Double = 16000

    func startRecording(onSamples: @escaping @Sendable ([Float]) -> Void) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!
        let rate = sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * rate / inputFormat.sampleRate
            )
            guard frameCount > 0 else { return }

            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            )!

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let channelData = convertedBuffer.floatChannelData {
                let count = Int(convertedBuffer.frameLength)
                let chunk = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: count
                ))
                onSamples(chunk)
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
}
