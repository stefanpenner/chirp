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
            vadPath: "/nonexistent/vad.onnx",
            variant: .tdt
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
