import Testing
@testable import Chirp

@Suite("TranscriptNormalize")
struct TranscriptNormalizeTests {
    @Test("key strips case and trailing punct")
    func key() {
        #expect(TranscriptNormalize.key("Hello World.") == "hello world")
        #expect(TranscriptNormalize.key("  HI!  ") == "hi")
        #expect(TranscriptNormalize.key("") == "")
    }
}
