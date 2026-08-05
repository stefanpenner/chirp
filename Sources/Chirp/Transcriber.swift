// Transcriber.swift — Offline speech recognition via sherpa-onnx C API.
// Actor wrapping an offline recognizer (Parakeet TDT 0.6b v3) and Silero VAD.
// Conforms to TranscriberProtocol; used by AppState to process audio:
//   feedAudio()  → returns committed segments when VAD detects speech end
//   peekTranscription() → speculative preview of current pending audio
//   flush()      → transcribes any remaining audio at recording end

import Foundation
import CSherpaOnnx
import os

actor Transcriber: TranscriberProtocol {
    // nonisolated(unsafe) so deinit can clean up C resources
    nonisolated(unsafe) private var recognizer: OpaquePointer?
    nonisolated(unsafe) private var vad: OpaquePointer?
    private var pendingAudio: [Float] = []
    /// Last VAD model path — needed to recreate VAD when settings change.
    private var vadModelPath: String?
    /// Peek ASR cache: skip re-decode when pending sample count is unchanged.
    /// Cleared when pending is cleared (commit / flush / resetVAD).
    private var lastPeekPendingCount: Int?
    private var lastPeekText: String?
    /// Speech-window fingerprint from the last successful peek decode.
    /// Used to skip commit/flush re-decode when trailing silence grows pending
    /// but the energy-trimmed window is unchanged (`PeekCommitHyp.tla`).
    private var lastPeekSpeechSignature: DecodePolicy.SpeechWindowSignature?

    private func toCString(_ s: String) -> UnsafeMutablePointer<CChar> {
        return strdup(s)!
    }

    // MARK: - Initialization

    /// Configures the offline recognizer and VAD from model files on disk.
    /// Tries `InferenceProvider.asrCandidates` in order (CPU by default;
    /// optional CoreML via `CHIRP_ASR_PROVIDER`). Returns false if all fail.
    func initialize(paths: ModelPaths) -> Bool {
        let modelDir = paths.modelDir

        guard createRecognizer(modelDir: modelDir) else {
            Log.transcription.error("Failed to create offline recognizer (ASR providers)")
            return false
        }

        vadModelPath = paths.vadPath
        if !initializeVAD(vadPath: paths.vadPath) {
            Log.transcription.error("Failed to create VAD")
            return false
        }

        Log.transcription.info("Transcriber initialized successfully")
        return true
    }

    /// Recreate VAD with current `VadSettings` (pause length / sensitivity).
    /// Safe to call between sessions; clears pending audio and peek cache.
    func reconfigureVAD() {
        guard let path = vadModelPath else {
            Log.transcription.debug("reconfigureVAD: no vad path yet")
            return
        }
        pendingAudio.removeAll()
        clearPeekCache()
        if let existing = vad {
            SherpaOnnxDestroyVoiceActivityDetector(existing)
            vad = nil
        }
        if initializeVAD(vadPath: path) {
            Log.transcription.info(
                "VAD reconfigured silence=\(VadSettings.minSilenceDuration)s threshold=\(VadSettings.threshold)"
            )
        } else {
            Log.transcription.error("VAD reconfigure failed")
        }
    }

    /// Try preferred ASR providers in order until create succeeds.
    /// Prefers modified_beam_search + command hotwords when enough phrases
    /// encode; otherwise greedy_search (CommandNearMiss repairs commands).
    private func createRecognizer(modelDir: String) -> Bool {
        for provider in InferenceProvider.asrCandidates {
            if let handle = makeRecognizer(modelDir: modelDir, provider: provider, useHotwords: true) {
                recognizer = handle
                Log.transcription.info(
                    "Offline recognizer using provider=\(provider) decoding=modified_beam_search hotwords=on"
                )
                return true
            }
            if let handle = makeRecognizer(modelDir: modelDir, provider: provider, useHotwords: false) {
                recognizer = handle
                Log.transcription.info(
                    "Offline recognizer using provider=\(provider) decoding=greedy_search hotwords=off"
                )
                return true
            }
            Log.transcription.info("Provider \(provider) unavailable for ASR — trying next")
        }
        return false
    }

    private func makeRecognizer(
        modelDir: String,
        provider: String,
        useHotwords: Bool
    ) -> OpaquePointer? {
        let tokensPath = toCString("\(modelDir)/tokens.txt")
        let providerStr = toCString(provider)
        let modelTypeStr = toCString(ModelVariant.modelType)
        let emptyStr = toCString("")
        // Hotwords require modified_beam_search (sherpa-onnx); greedy ignores them.
        let decodingMethodStr = toCString(
            useHotwords ? "modified_beam_search" : "greedy_search"
        )
        let hotwordsPathStr: UnsafeMutablePointer<CChar>?
        // Bare-token hotwords only; skip beam if list is sparse (latency).
        if useHotwords,
           let path = CommandHotwords.ensureFileOnDisk(
             tokensPath: "\(modelDir)/tokens.txt"
           )
        {
            hotwordsPathStr = toCString(path)
        } else if useHotwords {
            // Sparse/empty encodable list → greedy (CommandNearMiss repairs).
            free(tokensPath); free(providerStr); free(modelTypeStr)
            free(emptyStr); free(decodingMethodStr)
            return nil
        } else {
            hotwordsPathStr = nil
        }

        let encoderPath = toCString("\(modelDir)/encoder.int8.onnx")
        let decoderPath = toCString("\(modelDir)/decoder.int8.onnx")
        let joinerPath = toCString("\(modelDir)/joiner.int8.onnx")

        defer {
            free(encoderPath); free(decoderPath); free(joinerPath)
            free(tokensPath); free(providerStr); free(modelTypeStr); free(emptyStr)
            free(decodingMethodStr)
            if let hotwordsPathStr { free(hotwordsPathStr) }
        }

        var modelConfig = SherpaOnnxOfflineModelConfig()

        var transducerConfig = SherpaOnnxOfflineTransducerModelConfig()
        transducerConfig.encoder = UnsafePointer(encoderPath)
        transducerConfig.decoder = UnsafePointer(decoderPath)
        transducerConfig.joiner = UnsafePointer(joinerPath)
        modelConfig.transducer = transducerConfig

        modelConfig.tokens = UnsafePointer(tokensPath)
        modelConfig.num_threads = 4
        modelConfig.debug = 0
        modelConfig.provider = UnsafePointer(providerStr)
        modelConfig.model_type = UnsafePointer(modelTypeStr)
        modelConfig.modeling_unit = UnsafePointer(emptyStr)
        modelConfig.bpe_vocab = UnsafePointer(emptyStr)
        modelConfig.telespeech_ctc = UnsafePointer(emptyStr)

        var featConfig = SherpaOnnxFeatureConfig()
        featConfig.sample_rate = Int32(DecodePolicy.sampleRate)
        featConfig.feature_dim = 80

        var lmConfig = SherpaOnnxOfflineLMConfig()
        lmConfig.model = UnsafePointer(emptyStr)
        lmConfig.scale = 1.0

        var hrConfig = SherpaOnnxHomophoneReplacerConfig()
        hrConfig.dict_dir = UnsafePointer(emptyStr)
        hrConfig.lexicon = UnsafePointer(emptyStr)
        hrConfig.rule_fsts = UnsafePointer(emptyStr)

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config = featConfig
        config.model_config = modelConfig
        config.lm_config = lmConfig
        config.decoding_method = UnsafePointer(decodingMethodStr)
        config.max_active_paths = CommandHotwords.maxActivePaths
        if let hotwordsPathStr {
            config.hotwords_file = UnsafePointer(hotwordsPathStr)
            config.hotwords_score = CommandHotwords.score
        } else {
            config.hotwords_file = UnsafePointer(emptyStr)
            config.hotwords_score = CommandHotwords.score
        }
        config.rule_fsts = UnsafePointer(emptyStr)
        config.rule_fars = UnsafePointer(emptyStr)
        config.blank_penalty = 0.0
        config.hr = hrConfig

        return SherpaOnnxCreateOfflineRecognizer(&config)
    }

    private func initializeVAD(vadPath: String) -> Bool {
        let vadModelStr = toCString(vadPath)
        let emptyStr = toCString("")
        let providerStr = toCString(InferenceProvider.vadProvider)

        defer {
            free(vadModelStr); free(emptyStr); free(providerStr)
        }

        var sileroConfig = SherpaOnnxSileroVadModelConfig()
        sileroConfig.model = UnsafePointer(vadModelStr)
        // User-tunable endpointing (VadSettings); defaults from DecodePolicy.
        sileroConfig.threshold = VadSettings.threshold
        sileroConfig.min_silence_duration = VadSettings.minSilenceDuration
        sileroConfig.min_speech_duration = DecodePolicy.vadMinSpeechDuration
        sileroConfig.window_size = Int32(DecodePolicy.vadWindowSize)
        sileroConfig.max_speech_duration = DecodePolicy.vadMaxSpeechDuration

        var tenVadConfig = SherpaOnnxTenVadModelConfig()
        tenVadConfig.model = UnsafePointer(emptyStr)
        tenVadConfig.threshold = 0.5
        tenVadConfig.min_silence_duration = 0.3
        tenVadConfig.min_speech_duration = 0.15
        tenVadConfig.window_size = 512
        tenVadConfig.max_speech_duration = 15.0

        var vadConfig = SherpaOnnxVadModelConfig()
        vadConfig.silero_vad = sileroConfig
        vadConfig.ten_vad = tenVadConfig
        vadConfig.sample_rate = 16000
        vadConfig.num_threads = 1
        vadConfig.provider = UnsafePointer(providerStr)
        vadConfig.debug = 0

        vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 30.0)
        return vad != nil
    }

    // MARK: - Audio processing

    /// Feeds raw audio into the VAD. Returns transcriptions for any
    /// complete speech segments the VAD has detected.
    ///
    /// When the VAD ends a segment, we transcribe `pendingAudio` (full raw
    /// buffer since last commit) rather than the VAD-trimmed segment.
    /// Silero's speech-onset lag otherwise clips leading words ("what time"
    /// → "time", "open the document" → "the document"). Same source as
    /// peek/flush so mid-recording commits match what the user previewed.
    func feedAudio(samples: [Float]) -> [String] {
        guard let vad = vad, recognizer != nil else { return [] }

        pendingAudio.append(contentsOf: samples)

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, ptr.baseAddress, Int32(samples.count))
        }

        // Drain VAD segment queue — segments are the endpointing signal only.
        var hadSegment = false
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            hadSegment = true
            if let segmentPtr = SherpaOnnxVoiceActivityDetectorFront(vad) {
                SherpaOnnxDestroySpeechSegment(segmentPtr)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }

        guard hadSegment else {
            Log.transcription.debug("feedAudio: pendingAudio=\(self.pendingAudio.count) committedSegments=0")
            return []
        }

        // Min length guard: too-short buffers are unreliable. Keep pendingAudio —
        // a false VAD endpoint must not wipe speech that continues after.
        guard DecodePolicy.canCommit(pendingSampleCount: pendingAudio.count) else {
            Log.transcription.debug("feedAudio: pendingAudio=\(self.pendingAudio.count) too short — keep buffer")
            return []
        }

        let window = Self.withSpeechWindow(pendingAudio)
        let text: String
        if DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: lastPeekSpeechSignature,
            cachedText: lastPeekText,
            windowSamples: window.samples,
            pendingSampleCount: pendingAudio.count
        ), let cached = lastPeekText {
            Log.transcription.debug(
                "feedAudio: reuse peek hyp pendingAudio=\(self.pendingAudio.count) text=\(cached)"
            )
            text = cached
        } else {
            text = transcribeSamples(window.samples, speechFrameCount: window.speechFrameCount)
        }
        // Empty ASR on a VAD endpoint is usually a false end (noise / mid-pause).
        // Keep pendingAudio so the next commit/flush still sees the full utterance.
        guard !text.isEmpty else {
            Log.transcription.debug("feedAudio: empty ASR on VAD endpoint — keep pendingAudio=\(self.pendingAudio.count)")
            return []
        }

        pendingAudio.removeAll()
        clearPeekCache()
        Log.transcription.debug("feedAudio: committed pendingAudio text=\(text)")
        return [text]
    }

    /// Returns a speculative transcription of pending (uncommitted) audio,
    /// capped to the last 5 seconds so inference time stays constant.
    /// Only transcribes when the VAD detects active speech to avoid
    /// hallucinated words (e.g. "Yeah", "hm..") from silence/noise.
    /// Reuses the last decode when `pendingAudio.count` is unchanged
    /// (`DecodePolicy.shouldReusePeek` / `PeekCache.tla`).
    func peekTranscription() -> String? {
        guard let vad else { return nil }
        let speechDetected = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
        guard speechDetected else {
            Log.transcription.debug("peek: pendingAudio=\(self.pendingAudio.count) speechDetected=false")
            return nil
        }
        let count = pendingAudio.count
        guard DecodePolicy.canPeek(pendingSampleCount: count, speechDetected: true) else {
            return nil
        }
        if DecodePolicy.shouldReusePeek(lastCount: lastPeekPendingCount, currentCount: count) {
            Log.transcription.debug(
                "peek: reuse cache pendingAudio=\(count) text=\(self.lastPeekText ?? "")"
            )
            return lastPeekText
        }
        let windowCount = DecodePolicy.peekWindowCount(pendingSampleCount: count)
        let samples = count > windowCount
            ? Array(pendingAudio.suffix(windowCount))
            : pendingAudio
        let window = Self.withSpeechWindow(samples)
        let text = transcribeSamples(window.samples, speechFrameCount: window.speechFrameCount)
        let result = text.isEmpty ? nil : text
        lastPeekPendingCount = count
        lastPeekText = result
        // Only cache speech-window signature for non-empty hyps (commit reuse).
        lastPeekSpeechSignature = result == nil
            ? nil
            : DecodePolicy.speechWindowSignature(window.samples)
        Log.transcription.debug("peek: pendingAudio=\(count) speechDetected=true text=\(text)")
        return result
    }

    /// Flushes the VAD and transcribes any remaining pending audio.
    /// Uses pendingAudio (same source as peek) instead of VAD segment
    /// audio to avoid onset-lag clipping the start of speech.
    func flush() -> String {
        guard let vad = vad else { return "" }

        SherpaOnnxVoiceActivityDetectorFlush(vad)

        // Check if the VAD had uncommitted speech to flush.
        var hasPendingSpeech = false
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            hasPendingSpeech = true
            if let ptr = SherpaOnnxVoiceActivityDetectorFront(vad) {
                SherpaOnnxDestroySpeechSegment(ptr)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }

        guard hasPendingSpeech, DecodePolicy.canCommit(pendingSampleCount: pendingAudio.count) else {
            Log.transcription.debug("flush: pendingAudio=\(self.pendingAudio.count) hasPendingSpeech=\(hasPendingSpeech) — skipped")
            pendingAudio.removeAll()
            clearPeekCache()
            return ""
        }

        let window = Self.withSpeechWindow(pendingAudio)
        var text: String
        if DecodePolicy.shouldReuseCommitHyp(
            cachedSignature: lastPeekSpeechSignature,
            cachedText: lastPeekText,
            windowSamples: window.samples,
            pendingSampleCount: pendingAudio.count
        ), let cached = lastPeekText {
            Log.transcription.debug(
                "flush: reuse peek hyp pendingAudio=\(self.pendingAudio.count) text=\(cached)"
            )
            text = cached
        } else {
            text = transcribeSamples(window.samples, speechFrameCount: window.speechFrameCount)
        }
        // Empty re-decode after live peeks → promote last peek (empty-total gap).
        if DecodePolicy.shouldPromotePeekOnEmptyFlush(
            flushText: text,
            lastPeekText: lastPeekText,
            hasPendingSpeech: true,
            pendingSampleCount: pendingAudio.count
        ), let peek = lastPeekText {
            Log.transcription.info(
                "flush: promote peek hyp after empty decode pendingAudio=\(self.pendingAudio.count) text=\(peek)"
            )
            text = peek
        }
        Log.transcription.debug("flush: pendingAudio=\(self.pendingAudio.count) hasPendingSpeech=true text=\(text)")
        pendingAudio.removeAll()
        clearPeekCache()
        return text
    }

    func resetVAD() {
        pendingAudio.removeAll()
        clearPeekCache()
        if let vad = vad {
            SherpaOnnxVoiceActivityDetectorReset(vad)
        }
    }

    private func clearPeekCache() {
        lastPeekPendingCount = nil
        lastPeekText = nil
        lastPeekSpeechSignature = nil
    }

    // MARK: - Decode window

    /// Energy-trimmed window plus count of frames above the energy threshold.
    /// `speechFrameCount` feeds `DecodeReject` (silence / low-energy garbage).
    struct SpeechWindow: Equatable, Sendable {
        let samples: [Float]
        let speechFrameCount: Int
    }

    /// Drop long leading *and* trailing near-silence before ASR, but keep
    /// ~200ms pre-roll / post-roll so true speech edges are not clipped.
    /// Reduces decode on pure silence padding while preserving onset/offset.
    ///
    /// Energy gate is adaptive by default (`DecodePolicy.adaptiveEnergyThreshold`):
    /// noise floor from frame RMS (20th percentile) × multiplier, floored at
    /// `energyMinFloor`. Pass `energyThreshold` to force a fixed gate (tests).
    /// Internal for tests.
    static func withSpeechWindow(
        _ samples: [Float],
        preRollSamples: Int = DecodePolicy.preRollSamples,
        postRollSamples: Int = DecodePolicy.postRollSamples,
        frameSamples: Int = DecodePolicy.energyFrameSamples,
        energyThreshold: Float? = nil
    ) -> SpeechWindow {
        // First pass: per-frame RMS for adaptive floor + speech classification.
        var frameRMS: [Float] = []
        var frameStarts: [Int] = []
        var i = 0
        while i + frameSamples <= samples.count {
            var sum: Float = 0
            let end = i + frameSamples
            for j in i..<end {
                let s = samples[j]
                sum += s * s
            }
            frameRMS.append(sqrtf(sum / Float(frameSamples)))
            frameStarts.append(i)
            i += frameSamples
        }

        let threshold = energyThreshold
            ?? DecodePolicy.adaptiveEnergyThreshold(frameRMS: frameRMS)

        var speechFrameCount = 0
        var firstSpeech: Int?
        var lastSpeech: Int?
        for (idx, rms) in frameRMS.enumerated() {
            if rms >= threshold {
                speechFrameCount += 1
                let start = frameStarts[idx]
                if firstSpeech == nil { firstSpeech = start }
                lastSpeech = start + frameSamples
            }
        }

        // Too short to trim usefully — still report energy frame count.
        guard samples.count > preRollSamples + postRollSamples + frameSamples else {
            return SpeechWindow(samples: samples, speechFrameCount: speechFrameCount)
        }

        guard let first = firstSpeech, let last = lastSpeech else {
            // All near-silent — leave unchanged for caller guards.
            return SpeechWindow(samples: samples, speechFrameCount: 0)
        }

        let start = max(0, first - preRollSamples)
        let end = min(samples.count, last + postRollSamples)
        if start == 0 && end == samples.count {
            return SpeechWindow(samples: samples, speechFrameCount: speechFrameCount)
        }
        return SpeechWindow(
            samples: Array(samples[start..<end]),
            speechFrameCount: speechFrameCount
        )
    }

    /// Back-compat alias used by older tests/call sites.
    static func withLeadingPreRoll(
        _ samples: [Float],
        preRollSamples: Int = DecodePolicy.preRollSamples,
        frameSamples: Int = DecodePolicy.energyFrameSamples,
        energyThreshold: Float? = nil
    ) -> [Float] {
        withSpeechWindow(
            samples,
            preRollSamples: preRollSamples,
            postRollSamples: 0,
            frameSamples: frameSamples,
            energyThreshold: energyThreshold
        ).samples
    }

    // MARK: - Inference

    /// Runs offline recognition on a buffer of samples. Thread-safe via actor isolation.
    /// Rejects extremely low-confidence hypotheses when token log-probs are present,
    /// and silence/low-energy garbage via `DecodeReject` when scores are nil.
    private func transcribeSamples(_ samples: [Float], speechFrameCount: Int) -> String {
        guard let recognizer = recognizer, !samples.isEmpty else { return "" }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                Int32(DecodePolicy.sampleRate),
                ptr.baseAddress,
                Int32(samples.count)
            )
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
            SherpaOnnxDestroyOfflineStream(stream)
            return ""
        }

        let text: String
        if let cText = resultPtr.pointee.text {
            text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }

        // Confidence gate (SOTA): drop only extreme low-confidence dumps.
        let count = Int(resultPtr.pointee.count)
        var logProbs: [Float]?
        if count > 0, let ptr = resultPtr.pointee.ys_log_probs {
            logProbs = Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        let mean = ConfidenceGate.meanLogProb(tokenLogProbs: logProbs)
        if !ConfidenceGate.accept(tokenLogProbs: logProbs) {
            let meanStr = mean.map { String(format: "%.2f", $0) } ?? "?"
            Log.transcription.info("Rejected low-confidence ASR (mean logp=\(meanStr)): \"\(text)\"")
            SherpaOnnxDestroyOfflineRecognizerResult(resultPtr)
            SherpaOnnxDestroyOfflineStream(stream)
            return ""
        }

        // Energy/silence gate: catch Parakeet silence hallucinations when log-probs are nil.
        if DecodeReject.shouldReject(
            hyp: text,
            meanLogProb: mean,
            speechFrameCount: speechFrameCount
        ) {
            Log.transcription.info(
                "Rejected silence/low-energy ASR (frames=\(speechFrameCount)): \"\(text)\""
            )
            SherpaOnnxDestroyOfflineRecognizerResult(resultPtr)
            SherpaOnnxDestroyOfflineStream(stream)
            return ""
        }

        SherpaOnnxDestroyOfflineRecognizerResult(resultPtr)
        SherpaOnnxDestroyOfflineStream(stream)

        return text
    }

    deinit {
        if let recognizer = recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
        if let vad = vad {
            SherpaOnnxDestroyVoiceActivityDetector(vad)
        }
    }
}
