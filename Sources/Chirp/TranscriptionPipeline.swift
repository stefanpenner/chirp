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
    /// - Parameter onPostProcessing: Called when transcription is complete and
    ///   post-processing (LLM/T5) is about to begin. Nil when no post-processing applies.
    func flush(onPostProcessing: (@Sendable () -> Void)?) async -> String

    /// Reset state for a new recording session.
    func resetVAD() async
}

extension TranscriptionPipeline {
    func flush() async -> String { await flush(onPostProcessing: nil) }
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
    private let speakerVerifier: (any SpeakerVerifying)?
    private let speakerThreshold: Float
    private var recentAudio: [Float] = []
    private static let maxRecentSamples = 16000 * 15  // 15s at 16kHz

    init(
        transcriber: any TranscriberProtocol,
        postProcessor: any TextPostProcessing = RegexPostProcessor(),
        speakerVerifier: (any SpeakerVerifying)? = nil,
        speakerThreshold: Float = 0.25
    ) {
        self.transcriber = transcriber
        self.postProcessor = postProcessor
        self.usesLLM = !(postProcessor is RegexPostProcessor)
        self.speakerVerifier = speakerVerifier
        self.speakerThreshold = speakerThreshold
    }

    func feedAudio(samples: [Float]) async -> [String] {
        // Accumulate recent audio for speaker verification
        if speakerVerifier != nil {
            recentAudio.append(contentsOf: samples)
            if recentAudio.count > Self.maxRecentSamples {
                recentAudio.removeFirst(recentAudio.count - Self.maxRecentSamples)
            }
        }

        let segments = await transcriber.feedAudio(samples: samples)
        var results: [String] = []
        for raw in segments {
            let text = TextPostProcessor.process(raw)
            guard !text.isEmpty else { continue }

            // Speaker verification gate
            if let verifier = speakerVerifier, await verifier.hasReference {
                let audioToVerify = recentAudio
                recentAudio.removeAll()
                do {
                    let match = try await verifier.isMatch(samples: audioToVerify, threshold: speakerThreshold)
                    if !match {
                        Log.speaker.info("Segment rejected: speaker mismatch")
                        continue
                    }
                } catch {
                    // Graceful degradation: pass through on error
                    Log.speaker.error("Speaker verification failed, passing through: \(error.localizedDescription)")
                }
            }

            if usesLLM { accumulatedText.append(text) }
            results.append(text)
        }
        return results
    }

    func peekTranscription() async -> String? {
        guard let raw = await transcriber.peekTranscription() else { return nil }
        return TextPostProcessor.process(raw)
    }

    func flush(onPostProcessing: (@Sendable () -> Void)? = nil) async -> String {
        let raw = await transcriber.flush()
        let remaining = TextPostProcessor.process(raw)

        if usesLLM {
            if !remaining.isEmpty { accumulatedText.append(remaining) }
            let fullText = accumulatedText.joined(separator: " ")
            accumulatedText.removeAll()
            guard !fullText.isEmpty else { return "" }
            onPostProcessing?()
            // Run LLM post-processing on full text with retry, fallback to regex-cleaned text
            let processor = postProcessor
            do {
                return try await RetryHelper.withRetry {
                    try await processor.process(fullText)
                }
            } catch {
                Log.cloud.error("LLM post-processing failed, using regex-cleaned text: \(error.localizedDescription)")
                return fullText
            }
        } else {
            return remaining
        }
    }

    func resetVAD() async {
        accumulatedText.removeAll()
        recentAudio.removeAll()
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
    private var previewSegments: [String] = []
    private let sampleRate = 16000
    private let speakerVerifier: (any SpeakerVerifying)?
    private let speakerThreshold: Float

    init(
        sttClient: any STTClient,
        postProcessor: any TextPostProcessing = RegexPostProcessor(),
        localTranscriber: any TranscriberProtocol,
        speakerVerifier: (any SpeakerVerifying)? = nil,
        speakerThreshold: Float = 0.25
    ) {
        self.sttClient = sttClient
        self.postProcessor = postProcessor
        self.localTranscriber = localTranscriber
        self.speakerVerifier = speakerVerifier
        self.speakerThreshold = speakerThreshold
    }

    func feedAudio(samples: [Float]) async -> [String] {
        accumulatedSamples.append(contentsOf: samples)
        // Feed local transcriber for preview. Retain committed segments so
        // peek can show the full preview even after the VAD clears pendingAudio.
        let segments = await localTranscriber.feedAudio(samples: samples)
        for raw in segments {
            let text = TextPostProcessor.process(raw)
            if !text.isEmpty { previewSegments.append(text) }
        }
        return []
    }

    func peekTranscription() async -> String? {
        let peek = await localTranscriber.peekTranscription()
        let processedPeek = peek.flatMap { raw -> String? in
            let t = TextPostProcessor.process(raw)
            return t.isEmpty ? nil : t
        }
        let parts = previewSegments + [processedPeek].compactMap { $0 }
        let combined = parts.joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    func flush(onPostProcessing: (@Sendable () -> Void)? = nil) async -> String {
        // Flush local transcriber (discard result — it was only for preview)
        _ = await localTranscriber.flush()

        defer {
            accumulatedSamples.removeAll()
            previewSegments.removeAll()
        }
        guard !accumulatedSamples.isEmpty else { return "" }

        // Speaker verification gate: check accumulated audio before sending to cloud
        if let verifier = speakerVerifier, await verifier.hasReference {
            do {
                let match = try await verifier.isMatch(samples: accumulatedSamples, threshold: speakerThreshold)
                if !match {
                    Log.speaker.info("Cloud flush rejected: speaker mismatch")
                    return ""
                }
            } catch {
                Log.speaker.error("Speaker verification failed in cloud flush, passing through: \(error.localizedDescription)")
            }
        }

        let client = sttClient
        let samples = accumulatedSamples
        let rate = sampleRate
        let processor = postProcessor
        do {
            let raw = try await RetryHelper.withRetry {
                try await client.transcribe(samples: samples, sampleRate: rate)
            }
            onPostProcessing?()
            // Try full post-processing with retry, fall back to regex on LLM error
            do {
                return try await RetryHelper.withRetry {
                    try await processor.process(raw)
                }
            } catch {
                Log.cloud.error("Post-processing failed, falling back to regex: \(error.localizedDescription)")
                return TextPostProcessor.process(raw)
            }
        } catch {
            // Cloud STT failed — log and return empty
            Log.cloud.error("Cloud STT failed: \(error.localizedDescription)")
            return ""
        }
    }

    func resetVAD() async {
        accumulatedSamples.removeAll()
        previewSegments.removeAll()
        await localTranscriber.resetVAD()
    }
}
