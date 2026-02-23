// TranscriptionPipeline.swift — High-level transcription abstraction.
//
// TranscriptionPipeline (protocol)
// +-- OfflineTranscriptionPipeline  wraps existing Transcriber + RegexPostProcessor
// +-- CloudTranscriptionPipeline    accumulates audio, sends to cloud on flush
//
// AppState delegates to the active pipeline instead of calling transcriber
// and TextPostProcessor directly. The pipeline handles both transcription
// and post-processing, returning final text ready for insertion.

import Foundation

// MARK: - Protocol

/// A transcription pipeline that processes audio and returns cleaned text.
/// Offline pipelines stream results incrementally (via feedAudio returning segments).
/// Cloud pipelines accumulate audio and process everything on flush.
protocol TranscriptionPipeline: Sendable {
    /// Feed audio samples. Returns post-processed text segments (may be empty for cloud/LLM).
    func feedAudio(samples: [Float]) async -> [String]

    /// Peek at uncommitted audio. Returns speculative preview or nil.
    func peekTranscription() async -> String?

    /// Flush remaining audio and return final post-processed text.
    func flush() async -> String

    /// Reset state for a new recording session.
    func resetVAD() async
}

// MARK: - Offline Pipeline

/// Wraps the existing local Transcriber + regex post-processing.
/// Preserves all existing behavior: streaming segments, speculative peek, etc.
///
/// When `usesLLM` is true, feedAudio accumulates segments internally and
/// flush returns the LLM-processed full text. This prevents incremental
/// typing during recording when LLM post-processing is enabled.
actor OfflineTranscriptionPipeline: TranscriptionPipeline {
    let transcriber: any TranscriberProtocol
    let postProcessor: any TextPostProcessing
    let usesLLM: Bool
    private var accumulatedText: [String] = []

    init(transcriber: any TranscriberProtocol, postProcessor: any TextPostProcessing = RegexPostProcessor()) {
        self.transcriber = transcriber
        self.postProcessor = postProcessor
        self.usesLLM = !(postProcessor is RegexPostProcessor)
    }

    func feedAudio(samples: [Float]) async -> [String] {
        let segments = await transcriber.feedAudio(samples: samples)
        var results: [String] = []
        for raw in segments {
            let text = TextPostProcessor.process(raw)
            guard !text.isEmpty else { continue }
            if usesLLM { accumulatedText.append(text) }
            results.append(text)
        }
        return results
    }

    func peekTranscription() async -> String? {
        guard let raw = await transcriber.peekTranscription() else { return nil }
        return TextPostProcessor.process(raw)
    }

    func flush() async -> String {
        let raw = await transcriber.flush()
        let remaining = TextPostProcessor.process(raw)

        if usesLLM {
            if !remaining.isEmpty { accumulatedText.append(remaining) }
            let fullText = accumulatedText.joined(separator: " ")
            accumulatedText.removeAll()
            guard !fullText.isEmpty else { return "" }
            // Run LLM post-processing on full text, fallback to regex-cleaned text
            return (try? await postProcessor.process(fullText)) ?? fullText
        } else {
            return remaining
        }
    }

    func resetVAD() async {
        accumulatedText.removeAll()
        await transcriber.resetVAD()
    }
}

// MARK: - Cloud Pipeline

/// Accumulates audio during recording, then sends to a cloud STT service on flush.
/// No incremental text during recording — text typed once after cloud returns.
/// Uses the local transcriber in parallel for speculative preview during recording.
/// Post-processing (regex, LLM, or chained) runs after cloud STT returns.
actor CloudTranscriptionPipeline: TranscriptionPipeline {
    let sttClient: any STTClient
    let postProcessor: any TextPostProcessing
    let localTranscriber: any TranscriberProtocol
    private var accumulatedSamples: [Float] = []
    private let sampleRate = 16000

    init(sttClient: any STTClient, postProcessor: any TextPostProcessing = RegexPostProcessor(), localTranscriber: any TranscriberProtocol) {
        self.sttClient = sttClient
        self.postProcessor = postProcessor
        self.localTranscriber = localTranscriber
    }

    func feedAudio(samples: [Float]) async -> [String] {
        accumulatedSamples.append(contentsOf: samples)
        // Feed local transcriber for preview — discard segments (cloud handles final text)
        _ = await localTranscriber.feedAudio(samples: samples)
        return []
    }

    func peekTranscription() async -> String? {
        guard let raw = await localTranscriber.peekTranscription() else { return nil }
        return TextPostProcessor.process(raw)
    }

    func flush() async -> String {
        // Flush local transcriber (discard result — it was only for preview)
        _ = await localTranscriber.flush()

        defer { accumulatedSamples.removeAll() }
        guard !accumulatedSamples.isEmpty else { return "" }

        do {
            let raw = try await sttClient.transcribe(samples: accumulatedSamples, sampleRate: sampleRate)
            // Try full post-processing, fall back to regex on LLM error
            do {
                return try await postProcessor.process(raw)
            } catch {
                return TextPostProcessor.process(raw)
            }
        } catch {
            // Cloud STT failed — no fallback
            return ""
        }
    }

    func resetVAD() async {
        accumulatedSamples.removeAll()
        await localTranscriber.resetVAD()
    }
}
