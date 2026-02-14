import AVFoundation

@MainActor
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var samples: [Float] = []
    private let sampleRate: Double = 16000

    func startRecording() {
        samples = []
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

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
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
                let newSamples = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: count
                ))
                DispatchQueue.main.async {
                    self.samples.append(contentsOf: newSamples)
                }
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    func stopRecording() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        let result = samples
        samples = []
        return result
    }
}
