// OfflinePipelineBatchTests.swift — Batch (LLM/T5) path: no mid-session typing.

import Testing
@testable import Chirp

/// Marks content so we can see the processor ran.
private struct FakeBatchProcessor: TextPostProcessing {
    func process(_ text: String) async throws -> String {
        "BATCH[\(text)]"
    }
}

@Suite("OfflineTranscriptionPipeline batch mode")
struct OfflinePipelineBatchTests {

    @Test("defersTypingUntilFlush is false for regex and passthrough")
    func policyIncremental() {
        #expect(!TextPostProcessingPolicy.defersTypingUntilFlush(RegexPostProcessor()))
        #expect(!TextPostProcessingPolicy.defersTypingUntilFlush(PassthroughPostProcessor()))
    }

    @Test("defersTypingUntilFlush is true for batch processors")
    func policyBatch() {
        #expect(TextPostProcessingPolicy.defersTypingUntilFlush(FakeBatchProcessor()))
    }

    @Test("batch feed returns empty; flush joins and post-processes once")
    func batchAccumulateUntilFlush() async {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello", "world"])
        await mock.setFlushResult("done")

        let pipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: FakeBatchProcessor()
        )
        #expect(await pipeline.usesLLM)

        let mid = await pipeline.feedAudio(samples: [0.1])
        #expect(mid.isEmpty, "batch mode must not surface mid-session segments")

        let flushed = await pipeline.flush()
        // SegmentJoiner: "Hello" + "world" → "Hello world", + "done"
        #expect(flushed.hasPrefix("BATCH["))
        #expect(flushed.contains("Hello"))
        #expect(flushed.contains("world") || flushed.contains("World") || flushed.contains("done"))
        #expect(flushed.hasSuffix("]"))
    }

    @Test("batch mode does not accumulate spoken commands into join")
    func batchSkipsCommands() async {
        let mock = MockTranscriber()
        // First chunk: content; second would be command if returned mid-session
        await mock.setFeedAudioHandler { _ in ["Hello world"] }
        await mock.setFlushResult("scratch that")

        let pipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: FakeBatchProcessor()
        )
        _ = await pipeline.feedAudio(samples: [0.1])
        let flushed = await pipeline.flush()
        // Content is batched; trailing command alone with prior content is dropped from join
        #expect(flushed.contains("Hello"))
        #expect(!flushed.lowercased().contains("scratch"))
    }

    @Test("batch flush of command-only session surfaces the command")
    func batchCommandOnlyFlush() async {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult([])
        await mock.setFlushResult("scratch that")

        let pipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: FakeBatchProcessor()
        )
        let flushed = await pipeline.flush()
        #expect(DictationCommand.parse(flushed) == .scratchThat)
    }

    @Test("regex mode still returns mid-session segments")
    func regexIncremental() async {
        let mock = MockTranscriber()
        await mock.setFeedAudioResult(["Hello"])
        await mock.setFlushResult("world")

        let pipeline = OfflineTranscriptionPipeline(
            transcriber: mock,
            postProcessor: RegexPostProcessor()
        )
        #expect(await !pipeline.usesLLM)

        let mid = await pipeline.feedAudio(samples: [0.1])
        #expect(mid == ["Hello"])
        let flushed = await pipeline.flush()
        #expect(flushed == "world" || flushed == "World")
    }
}
