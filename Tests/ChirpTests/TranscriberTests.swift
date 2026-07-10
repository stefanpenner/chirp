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

    @Test("withLeadingPreRoll keeps short buffers unchanged")
    func preRollShortUnchanged() {
        let samples = [Float](repeating: 0.1, count: 1000)
        let out = Transcriber.withLeadingPreRoll(samples)
        #expect(out.count == samples.count)
    }

    @Test("withLeadingPreRoll drops long leading silence but keeps pre-roll")
    func preRollDropsLeadingSilence() {
        // 1s silence + 0.5s speech-like energy
        var samples = [Float](repeating: 0, count: 16000)
        samples += [Float](repeating: 0.2, count: 8000)
        let out = Transcriber.withLeadingPreRoll(
            samples,
            preRollSamples: 3200,
            frameSamples: 320,
            energyThreshold: 0.01
        )
        // Should start ~200ms before speech, not at sample 0
        #expect(out.count < samples.count)
        #expect(out.count >= 8000 + 3200 - 320) // speech + pre-roll - one frame slack
        // Peak energy preserved
        #expect((out.map { abs($0) }.max() ?? 0) >= 0.2)
    }

    @Test("withLeadingPreRoll keeps full buffer when all silent")
    func preRollAllSilentKeepsAll() {
        let samples = [Float](repeating: 0, count: 16000)
        let out = Transcriber.withLeadingPreRoll(samples)
        #expect(out.count == samples.count)
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
