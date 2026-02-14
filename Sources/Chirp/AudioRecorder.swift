import AVFoundation

@MainActor
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private let sampleRate: Double = 16000
    private var onSamples: (([Float]) -> Void)?

    /// Start recording. Each chunk of resampled 16kHz mono audio calls `onSamples`.
    func startRecording(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
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
                let chunk = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: count
                ))
                self.onSamples?(chunk)
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
        onSamples = nil
    }
}
