import Foundation
import CSherpaOnnx

final class Transcriber: @unchecked Sendable {
    private var recognizer: OpaquePointer?
    private var vad: OpaquePointer?
    private let lock = NSLock()
    private var pendingAudio: [Float] = []

    private func toCString(_ s: String) -> UnsafeMutablePointer<CChar> {
        return strdup(s)!
    }

    func initialize(paths: ModelPaths) -> Bool {
        let modelDir = paths.modelDir
        let variant = paths.variant

        // --- Offline recognizer ---
        let tokensPath = toCString("\(modelDir)/tokens.txt")
        let providerStr = toCString("cpu")
        let modelTypeStr = toCString(variant.modelType)
        let emptyStr = toCString("")
        let decodingMethodStr = toCString("greedy_search")

        // Variant-specific paths
        let encoderPath = toCString("\(modelDir)/encoder.int8.onnx")
        let decoderPath = toCString("\(modelDir)/decoder.int8.onnx")
        let joinerPath = toCString("\(modelDir)/joiner.int8.onnx")
        let ctcModelPath = toCString("\(modelDir)/model.int8.onnx")

        defer {
            free(encoderPath); free(decoderPath); free(joinerPath); free(ctcModelPath)
            free(tokensPath); free(providerStr); free(modelTypeStr); free(emptyStr)
            free(decodingMethodStr)
        }

        var modelConfig = SherpaOnnxOfflineModelConfig()

        switch variant {
        case .tdt:
            var transducerConfig = SherpaOnnxOfflineTransducerModelConfig()
            transducerConfig.encoder = UnsafePointer(encoderPath)
            transducerConfig.decoder = UnsafePointer(decoderPath)
            transducerConfig.joiner = UnsafePointer(joinerPath)
            modelConfig.transducer = transducerConfig
        case .ctc:
            var ctcConfig = SherpaOnnxOfflineNemoEncDecCtcModelConfig()
            ctcConfig.model = UnsafePointer(ctcModelPath)
            modelConfig.nemo_ctc = ctcConfig
        }

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
            NSLog("Chirp: Failed to create offline recognizer")
            return false
        }

        // --- VAD ---
        if !initializeVAD(vadPath: paths.vadPath) {
            NSLog("Chirp: Failed to create VAD")
            return false
        }

        NSLog("Chirp: Transcriber initialized successfully")
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
        sileroConfig.min_silence_duration = 0.15
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

    /// Feed audio to VAD and return completed speech segments' transcriptions.
    func feedAudio(samples: [Float]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let vad = vad, recognizer != nil else { return [] }

        pendingAudio.append(contentsOf: samples)

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, ptr.baseAddress, Int32(samples.count))
        }

        var results: [String] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let segmentPtr = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let segment = segmentPtr.pointee

            if segment.n > 0, let samplesPtr = segment.samples {
                let segmentSamples = Array(UnsafeBufferPointer(start: samplesPtr, count: Int(segment.n)))
                let text = transcribeSamples(segmentSamples)
                if !text.isEmpty {
                    results.append(text)
                }
            }

            SherpaOnnxDestroySpeechSegment(segmentPtr)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }

        if !results.isEmpty {
            pendingAudio.removeAll()
        }

        return results
    }

    /// Speculatively transcribe buffered audio for live preview.
    /// Returns nil if not enough audio accumulated yet.
    func peekTranscription() -> String? {
        lock.lock()
        defer { lock.unlock() }
        // Need at least ~0.3s of audio (4800 samples at 16kHz)
        guard pendingAudio.count >= 4800 else { return nil }
        let text = transcribeSamples(pendingAudio)
        return text.isEmpty ? nil : text
    }

    /// Flush any remaining audio in the VAD and transcribe it.
    func flush() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let vad = vad else { return "" }

        SherpaOnnxVoiceActivityDetectorFlush(vad)

        var allText = ""
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let segmentPtr = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let segment = segmentPtr.pointee

            if segment.n > 0, let samplesPtr = segment.samples {
                let segmentSamples = Array(UnsafeBufferPointer(start: samplesPtr, count: Int(segment.n)))
                let text = transcribeSamples(segmentSamples)
                if !text.isEmpty {
                    if !allText.isEmpty { allText += " " }
                    allText += text
                }
            }

            SherpaOnnxDestroySpeechSegment(segmentPtr)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }

        return allText
    }

    /// Reset VAD state for a new recording session.
    func resetVAD() {
        lock.lock()
        defer { lock.unlock() }
        pendingAudio.removeAll()
        if let vad = vad {
            SherpaOnnxVoiceActivityDetectorReset(vad)
        }
    }

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
