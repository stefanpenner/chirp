import Foundation
import CSherpaOnnx

final class Transcriber: @unchecked Sendable {
    private var recognizer: OpaquePointer?

    private func toCString(_ s: String) -> UnsafeMutablePointer<CChar> {
        return strdup(s)!
    }

    func initialize(modelDir: String) -> Bool {
        let encoderPath = toCString("\(modelDir)/encoder.int8.onnx")
        let decoderPath = toCString("\(modelDir)/decoder.int8.onnx")
        let joinerPath = toCString("\(modelDir)/joiner.int8.onnx")
        let tokensPath = toCString("\(modelDir)/tokens.txt")
        let providerStr = toCString("cpu")
        let modelTypeStr = toCString("nemo_transducer")
        let emptyStr = toCString("")
        let decodingMethodStr = toCString("greedy_search")

        defer {
            free(encoderPath)
            free(decoderPath)
            free(joinerPath)
            free(tokensPath)
            free(providerStr)
            free(modelTypeStr)
            free(emptyStr)
            free(decodingMethodStr)
        }

        var transducerConfig = SherpaOnnxOfflineTransducerModelConfig()
        transducerConfig.encoder = UnsafePointer(encoderPath)
        transducerConfig.decoder = UnsafePointer(decoderPath)
        transducerConfig.joiner = UnsafePointer(joinerPath)

        var modelConfig = SherpaOnnxOfflineModelConfig()
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
            NSLog("Yodel: Failed to create offline recognizer")
            return false
        }

        NSLog("Yodel: Transcriber initialized successfully")
        return true
    }

    /// Transcribes audio samples. This is a blocking CPU-intensive call.
    /// Call from a background thread.
    func transcribe(samples: [Float]) -> String {
        guard let recognizer = recognizer else {
            print("Transcriber not initialized")
            return ""
        }

        guard !samples.isEmpty else {
            return ""
        }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            print("Failed to create offline stream")
            return ""
        }

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
    }
}
