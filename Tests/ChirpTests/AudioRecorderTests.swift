// AudioRecorderTests.swift — Smoke tests for the audio tap block.
// Verifies that audio samples flow through makeTapBlock without being
// dropped. These tests don't need a microphone or ML model — they exercise
// the sample-rate conversion and channel-extraction logic directly.
// Also covers yodel-adv1 (bounded backlog / hop) and yodel-adv2 (live slot).

import Testing
import AVFoundation
@testable import Chirp

@Suite("AudioRecorder tap block")
struct AudioRecorderTapBlockTests {

    // MARK: - Helpers

    /// Create a mono Float32 PCM buffer filled with a sine wave.
    private static func sineBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        frameCount: AVAudioFrameCount = 4096,
        amplitude: Float = 0.3
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Fill channel 0 with sine; leave others silent (tests channel extraction)
        if let ch0 = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                ch0[i] = sin(Float(i) * 0.1) * amplitude
            }
        }
        return buffer
    }

    /// Thread-safe collector for samples received from the tap block.
    final class SampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples: [[Float]] = []

        func append(_ chunk: [Float]) {
            lock.lock()
            _samples.append(chunk)
            lock.unlock()
        }

        var samples: [[Float]] {
            lock.lock()
            defer { lock.unlock() }
            return _samples
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _samples.count
        }
    }

    private static func makeFormats(
        srcRate: Double,
        dstRate: Double,
        srcChannels: AVAudioChannelCount
    ) -> (converter: AVAudioConverter, dst: AVAudioFormat) {
        let convSrcFormat: AVAudioFormat
        if srcChannels > 1 {
            convSrcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcRate,
                channels: 1,
                interleaved: false
            )!
        } else {
            convSrcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcRate,
                channels: srcChannels,
                interleaved: false
            )!
        }
        let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: dstRate,
            channels: 1,
            interleaved: false
        )!
        let converter = AVAudioConverter(from: convSrcFormat, to: dstFormat)!
        return (converter, dstFormat)
    }

    private static func makeTap(
        srcRate: Double = 48000,
        dstRate: Double = 16000,
        srcChannels: AVAudioChannelCount = 1
    ) -> (tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
          received: SampleCollector) {

        let (converter, dstFormat) = makeFormats(
            srcRate: srcRate, dstRate: dstRate, srcChannels: srcChannels
        )
        let received = SampleCollector()
        let tap = AudioRecorder.makeTapBlock(
            converter: converter,
            targetFormat: dstFormat,
            inputSampleRate: srcRate,
            outputRate: dstRate,
            onSamples: { samples in
                received.append(samples)
            }
        )
        return (tap, received)
    }

    private static let dummyTime = AVAudioTime(sampleTime: 0, atRate: 48000)

    // MARK: - Tests

    @Test("Normal audio passes through tap block")
    func normalAudioPassesThrough() {
        let (tap, received) = Self.makeTap()

        let buffer = Self.sineBuffer(sampleRate: 48000)
        tap(buffer, Self.dummyTime)

        #expect(!received.samples.isEmpty, "Tap block should deliver samples for normal audio")
        #expect(received.samples[0].count > 0, "Delivered samples should be non-empty")
    }

    @Test("Quiet audio still passes through (no silence gate)")
    func quietAudioPassesThrough() {
        let (tap, received) = Self.makeTap()

        // Very quiet signal — RMS ≈ 0.0007, well below any reasonable gate
        let buffer = Self.sineBuffer(sampleRate: 48000, amplitude: 0.001)
        tap(buffer, Self.dummyTime)

        #expect(!received.samples.isEmpty,
                "Quiet audio must not be dropped — silence gating breaks transcription")
    }

    @Test("Multi-channel input extracts channel 0")
    func multiChannelExtraction() {
        // VP can expose 9+ channels; tap block should extract ch0
        let (tap, received) = Self.makeTap(srcChannels: 2)

        let buffer = Self.sineBuffer(sampleRate: 48000, channels: 2)
        tap(buffer, Self.dummyTime)

        #expect(!received.samples.isEmpty, "Multi-channel audio should produce output")
        #expect(received.samples[0].count > 0)
    }

    @Test("Sample rate conversion produces expected frame count")
    func sampleRateConversion() {
        let (tap, received) = Self.makeTap(srcRate: 48000, dstRate: 16000)

        let buffer = Self.sineBuffer(sampleRate: 48000, frameCount: 4800)  // 100ms
        tap(buffer, Self.dummyTime)

        #expect(!received.samples.isEmpty)
        // 4800 frames at 48kHz → 1600 frames at 16kHz
        let count = received.samples[0].count
        #expect(count > 1400 && count < 1800,
                "Expected ~1600 samples, got \(count)")
    }

    @Test("Multiple buffers accumulate correctly")
    func multipleBuffers() {
        let (tap, received) = Self.makeTap()

        for _ in 0..<5 {
            let buffer = Self.sineBuffer(sampleRate: 48000, frameCount: 1024)
            tap(buffer, Self.dummyTime)
        }

        #expect(received.samples.count == 5,
                "Each buffer should produce one callback, got \(received.samples.count)")
    }

    // MARK: - yodel-adv1 / adv2

    @Test("Capture policy bounds are positive and finite")
    func capturePolicyBounds() {
        #expect(AudioCapturePolicy.streamBufferChunks > 0)
        #expect(AudioCapturePolicy.streamBufferChunks <= 256)
        #expect(AudioCapturePolicy.maxPendingConverts > 0)
        #expect(AudioCapturePolicy.maxPendingConverts <= 64)
    }

    @Test("ConvertBacklog drops when at capacity (yodel-adv1)")
    func convertBacklogDropsWhenFull() {
        let backlog = ConvertBacklog(maxPending: 2)
        #expect(backlog.tryAcquire())
        #expect(backlog.tryAcquire())
        #expect(!backlog.tryAcquire(), "Third acquire must fail at capacity")
        backlog.release()
        #expect(backlog.tryAcquire(), "Release frees a slot")
        backlog.release()
        backlog.release()
        #expect(backlog.pending == 0)
    }

    @Test("Live converter slot is visible to tap after update (yodel-adv2)")
    func liveConverterSlotUpdate() {
        let (conv48, dst) = Self.makeFormats(srcRate: 48000, dstRate: 16000, srcChannels: 1)
        let slot = AudioConverterSlot(
            converter: conv48,
            targetFormat: dst,
            inputSampleRate: 48000,
            outputRate: 16000
        )
        let received = SampleCollector()
        let tap = AudioRecorder.makeTapBlock(
            slot: slot,
            convertQueue: nil,
            backlog: nil,
            onSamples: { received.append($0) }
        )

        // First buffer at 48 kHz → ~1600 @ 16 kHz for 4800 frames
        tap(Self.sineBuffer(sampleRate: 48000, frameCount: 4800), Self.dummyTime)
        #expect(received.count == 1)
        let firstCount = received.samples[0].count
        #expect(firstCount > 1400 && firstCount < 1800)

        // Swap to 24 kHz source converter mid-session (stale path would keep 48 kHz math)
        let (conv24, _) = Self.makeFormats(srcRate: 24000, dstRate: 16000, srcChannels: 1)
        slot.update(
            converter: conv24,
            targetFormat: dst,
            inputSampleRate: 24000,
            outputRate: 16000
        )
        tap(Self.sineBuffer(sampleRate: 24000, frameCount: 2400), Self.dummyTime)
        #expect(received.count == 2)
        // 2400 @ 24 kHz → 1600 @ 16 kHz
        let secondCount = received.samples[1].count
        #expect(secondCount > 1400 && secondCount < 1800,
                "Live slot must use updated rate; got \(secondCount)")
    }

    @Test("Async hop delivers samples off the caller's thread (yodel-adv1)")
    func asyncHopDelivers() async {
        let (converter, dst) = Self.makeFormats(srcRate: 48000, dstRate: 16000, srcChannels: 1)
        let slot = AudioConverterSlot(
            converter: converter,
            targetFormat: dst,
            inputSampleRate: 48000,
            outputRate: 16000
        )
        let backlog = ConvertBacklog(maxPending: 8)
        let received = SampleCollector()
        let queue = DispatchQueue(label: "test.chirp.convert")
        let tap = AudioRecorder.makeTapBlock(
            slot: slot,
            convertQueue: queue,
            backlog: backlog,
            onSamples: { received.append($0) }
        )

        tap(Self.sineBuffer(sampleRate: 48000, frameCount: 4800), Self.dummyTime)

        // Drain hop queue then observe delivery.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
        #expect(received.count == 1, "Hop must deliver converted chunk")
        #expect(received.samples[0].count > 1400)
        #expect(backlog.pending == 0)
    }

    @Test("In-flight hop keeps tap-time snapshot after mid-queue rebuild (yodel-adv2)")
    func inFlightHopKeepsTapSnapshot() async {
        let (conv48, dst) = Self.makeFormats(srcRate: 48000, dstRate: 16000, srcChannels: 1)
        let slot = AudioConverterSlot(
            converter: conv48,
            targetFormat: dst,
            inputSampleRate: 48000,
            outputRate: 16000
        )
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.chirp.convert.gate")
        let received = SampleCollector()
        let tap = AudioRecorder.makeTapBlock(
            slot: slot,
            convertQueue: queue,
            backlog: ConvertBacklog(maxPending: 8),
            onSamples: { received.append($0) }
        )

        // Block the convert queue so the hop stays in-flight.
        queue.async { gate.wait() }

        tap(Self.sineBuffer(sampleRate: 48000, frameCount: 4800), Self.dummyTime)

        // Rebuild slot while hop is queued (would poison convert if re-read live).
        let (conv24, _) = Self.makeFormats(srcRate: 24000, dstRate: 16000, srcChannels: 1)
        slot.update(
            converter: conv24,
            targetFormat: dst,
            inputSampleRate: 24000,
            outputRate: 16000
        )

        gate.signal()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }

        #expect(received.count == 1)
        // 4800 @ 48 kHz → ~1600; wrong (24 kHz) math would yield ~3200.
        let count = received.samples[0].count
        #expect(count > 1400 && count < 1800,
                "In-flight buffer must use 48 kHz snapshot; got \(count)")
    }
}
