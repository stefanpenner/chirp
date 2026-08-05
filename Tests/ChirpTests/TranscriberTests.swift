import Testing
@testable import Chirp

@Suite("Transcriber")
struct TranscriberTests {

    @Test("feedAudio returns empty without initialization")
    func feedAudioWithoutInit() async {
        let t = Transcriber()
        let result = await t.feedAudio(samples: [0.1, 0.2, 0.3])
        #expect(result.isEmpty)
    }

    @Test("withSpeechWindow keeps short buffers unchanged")
    func speechWindowShortUnchanged() {
        // Too short to trim; still report energy frames.
        // Mix quiet + louder so adaptive floor stays below speech peaks
        // (uniform amplitude would sit at the noise percentile).
        var samples = [Float](repeating: 0.02, count: 400)
        samples += [Float](repeating: 0.2, count: 600)
        let out = Transcriber.withSpeechWindow(samples)
        #expect(out.samples.count == samples.count)
        #expect(out.speechFrameCount > 0)
    }

    @Test("withSpeechWindow trims leading and trailing silence with rolls")
    func speechWindowTrimsBothEnds() {
        // 1s silence + 0.5s speech + 1s silence
        var samples = [Float](repeating: 0, count: 16000)
        samples += [Float](repeating: 0.2, count: 8000)
        samples += [Float](repeating: 0, count: 16000)
        let out = Transcriber.withSpeechWindow(
            samples,
            preRollSamples: 3200,
            postRollSamples: 3200,
            frameSamples: 320,
            energyThreshold: 0.01
        )
        #expect(out.samples.count < samples.count)
        // speech + pre + post - frame slack
        #expect(out.samples.count >= 8000 + 3200 + 3200 - 640)
        #expect(out.samples.count <= 8000 + 3200 + 3200 + 640)
        #expect((out.samples.map { abs($0) }.max() ?? 0) >= 0.2)
        // 0.5s speech / 320-sample frames ≈ 25
        #expect(out.speechFrameCount >= 20)
        #expect(out.speechFrameCount <= 30)
    }

    @Test("withSpeechWindow keeps full buffer when all silent and reports zero frames")
    func speechWindowAllSilentKeepsAll() {
        let samples = [Float](repeating: 0, count: 16000)
        let out = Transcriber.withSpeechWindow(samples)
        #expect(out.samples.count == samples.count)
        #expect(out.speechFrameCount == 0)
    }

    @Test("withSpeechWindow adaptive floor: room noise alone is not speech")
    func speechWindowRoomNoiseNotSpeech() {
        // Constant ~0.02: noiseFloor≈peak → thr above all frames → 0 speech.
        let samples = [Float](repeating: 0.02, count: 32_000)
        let out = Transcriber.withSpeechWindow(samples)
        #expect(out.speechFrameCount == 0)
        #expect(out.samples.count == samples.count)
    }

    @Test("withSpeechWindow adaptive floor: finds speech burst above room noise")
    func speechWindowSpeechAboveRoomNoise() {
        // Quiet room (~0.02) + 0.5s speech burst (0.3) + quiet tail.
        var samples = [Float](repeating: 0.02, count: 16_000)
        samples += [Float](repeating: 0.3, count: 8_000)
        samples += [Float](repeating: 0.02, count: 16_000)
        let out = Transcriber.withSpeechWindow(samples)
        // ~0.5s / 20ms frames ≈ 25 speech frames — not the whole buffer.
        #expect(out.speechFrameCount >= 20)
        #expect(out.speechFrameCount <= 35)
        #expect(out.samples.count < samples.count)
        #expect((out.samples.map { abs($0) }.max() ?? 0) >= 0.3)
        // Pre/post roll preserved (~200ms each).
        #expect(out.samples.count >= 8_000 + 3_200 + 3_200 - 640)
        #expect(out.samples.count <= 8_000 + 3_200 + 3_200 + 640)
    }

    @Test("withSpeechWindow soft speech envelope still has speech frames")
    func speechWindowSoftContinuousSpeech() {
        // Soft talk with syllable-like peaks (must-shout bug: thr wiped all frames).
        var samples = [Float]()
        samples.reserveCapacity(16_000)
        for i in 0..<16_000 {
            // ~5 Hz envelope × soft carrier-ish levels
            let env: Float = (i % 3200 < 1600) ? 0.05 : 0.012
            samples.append(env)
        }
        let out = Transcriber.withSpeechWindow(samples)
        #expect(out.speechFrameCount > 0, "soft speech must not be frames=0")
    }

    @Test("withSpeechWindow explicit threshold still overrides adaptive")
    func speechWindowExplicitThreshold() {
        // Room noise above fixed low thr counts as speech when override is fixed.
        let samples = [Float](repeating: 0.02, count: 16_000)
        let adaptive = Transcriber.withSpeechWindow(samples)
        let fixed = Transcriber.withSpeechWindow(samples, energyThreshold: 0.005)
        // Explicit low fixed thr must count frames.
        #expect(fixed.speechFrameCount > 0)
        // Adaptive may or may not; fixed override is what we assert.
        _ = adaptive
    }

    @Test("withLeadingPreRoll alias still trims leading silence")
    func leadingPreRollAlias() {
        var samples = [Float](repeating: 0, count: 16000)
        samples += [Float](repeating: 0.2, count: 8000)
        let out = Transcriber.withLeadingPreRoll(samples, preRollSamples: 3200)
        #expect(out.count < samples.count)
        #expect(out.count >= 8000)
    }

    @Test("peekTranscription returns nil with insufficient audio")
    func peekWithoutEnoughAudio() async {
        let t = Transcriber()
        let result = await t.peekTranscription()
        #expect(result == nil)
    }

    @Test("initialize returns false with invalid paths")
    func initializeInvalidPaths() async {
        let t = Transcriber()
        let paths = ModelPaths(
            modelDir: "/nonexistent/path",
            vadPath: "/nonexistent/vad.onnx"
        )
        let ok = await t.initialize(paths: paths)
        #expect(!ok)
    }

    @Test("flush returns empty without initialization")
    func flushWithoutInit() async {
        let t = Transcriber()
        let result = await t.flush()
        #expect(result.isEmpty)
    }

    @Test("resetVAD doesn't crash without initialization")
    func resetVADWithoutInit() async {
        let t = Transcriber()
        await t.resetVAD()
        // No crash = pass
    }
}
