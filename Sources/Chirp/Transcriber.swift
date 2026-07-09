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

    private func toCString(_ s: String) -> UnsafeMutablePointer<CChar> {
        return strdup(s)!
    }

    // MARK: - Initialization

    /// Configures the offline recognizer and VAD from model files on disk.
    /// Returns false if either fails to initialize.
    func initialize(paths: ModelPaths) -> Bool {
        let modelDir = paths.modelDir

        let tokensPath = toCString("\(modelDir)/tokens.txt")
        let providerStr = toCString("cpu")
        let modelTypeStr = toCString(ModelVariant.modelType)
        let emptyStr = toCString("")
        let decodingMethodStr = toCString("greedy_search")

        let encoderPath = toCString("\(modelDir)/encoder.int8.onnx")
        let decoderPath = toCString("\(modelDir)/decoder.int8.onnx")
        let joinerPath = toCString("\(modelDir)/joiner.int8.onnx")

        defer {
            free(encoderPath); free(decoderPath); free(joinerPath)
            free(tokensPath); free(providerStr); free(modelTypeStr); free(emptyStr)
            free(decodingMethodStr)
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
        featConfig.sample_rate = 16000
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
        config.max_active_paths = 4
        config.hotwords_file = UnsafePointer(emptyStr)
        config.hotwords_score = 1.5
        config.rule_fsts = UnsafePointer(emptyStr)
        config.rule_fars = UnsafePointer(emptyStr)
        config.blank_penalty = 0.0
        config.hr = hrConfig

        recognizer = SherpaOnnxCreateOfflineRecognizer(&config)

        if recognizer == nil {
            Log.transcription.error("Failed to create offline recognizer")
            return false
        }

        if !initializeVAD(vadPath: paths.vadPath) {
            Log.transcription.error("Failed to create VAD")
            return false
        }

        Log.transcription.info("Transcriber initialized successfully")
        return true
    }

    private func initializeVAD(vadPath: String) -> Bool {
        let vadModelStr = toCString(vadPath)
        let emptyStr = toCString("")
        let providerStr = toCString("cpu")

        defer {
            free(vadModelStr); free(emptyStr); free(providerStr)
        }

        var sileroConfig = SherpaOnnxSileroVadModelConfig()
        sileroConfig.model = UnsafePointer(vadModelStr)
        sileroConfig.threshold = 0.45
        sileroConfig.min_silence_duration = 0.5
        sileroConfig.min_speech_duration = 0.1
        sileroConfig.window_size = 512
        sileroConfig.max_speech_duration = 15.0

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

        // Min length guard: too-short buffers are unreliable and may hallucinate.
        guard pendingAudio.count >= 1600 else {
            Log.transcription.debug("feedAudio: pendingAudio=\(self.pendingAudio.count) too short — skipped commit")
            pendingAudio.removeAll()
            return []
        }

        let text = transcribeSamples(pendingAudio)
        pendingAudio.removeAll()
        Log.transcription.debug("feedAudio: committed pendingAudio text=\(text)")
        return text.isEmpty ? [] : [text]
    }

    /// Returns a speculative transcription of pending (uncommitted) audio,
    /// capped to the last 5 seconds so inference time stays constant.
    /// Only transcribes when the VAD detects active speech to avoid
    /// hallucinated words (e.g. "Yeah", "hm..") from silence/noise.
    func peekTranscription() -> String? {
        guard let vad else { return nil }
        let speechDetected = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
        guard speechDetected else {
            Log.transcription.debug("peek: pendingAudio=\(self.pendingAudio.count) speechDetected=false")
            return nil
        }
        guard pendingAudio.count >= 4800 else { return nil }
        let maxSamples = 16000 * 5
        let samples = pendingAudio.count > maxSamples
            ? Array(pendingAudio.suffix(maxSamples))
            : pendingAudio
        let text = transcribeSamples(samples)
        Log.transcription.debug("peek: pendingAudio=\(self.pendingAudio.count) speechDetected=true text=\(text)")
        return text.isEmpty ? nil : text
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

        guard hasPendingSpeech, pendingAudio.count >= 1600 else {
            Log.transcription.debug("flush: pendingAudio=\(self.pendingAudio.count) hasPendingSpeech=\(hasPendingSpeech) — skipped")
            pendingAudio.removeAll()
            return ""
        }

        let text = transcribeSamples(pendingAudio)
        Log.transcription.debug("flush: pendingAudio=\(self.pendingAudio.count) hasPendingSpeech=true text=\(text)")
        pendingAudio.removeAll()
        return text
    }

    func resetVAD() {
        pendingAudio.removeAll()
        if let vad = vad {
            SherpaOnnxVoiceActivityDetectorReset(vad)
        }
    }

    // MARK: - Inference

    /// Runs offline recognition on a buffer of samples. Thread-safe via actor isolation.
    private func transcribeSamples(_ samples: [Float]) -> String {
        guard let recognizer = recognizer, !samples.isEmpty else { return "" }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, ptr.baseAddress, Int32(samples.count))
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
