// T5PostProcessor.swift — Offline T5-small inference for post-processing.
// Conforms to TextPostProcessing. Loads encoder + decoder ONNX sessions,
// runs autoregressive greedy decoding with task prefix.

import Foundation

/// Post-processes transcription text using a local T5-small ONNX model.
/// Runs encoder once, then iteratively decodes tokens until EOS or max length.
final class T5PostProcessor: TextPostProcessing, @unchecked Sendable {
    private let encoder: ONNXSession
    private let decoder: ONNXSession
    private let tokenizer: T5Tokenizer

    /// T5 task prefix for grammar/punctuation cleanup.
    static let taskPrefix = "fix grammar and punctuation: "

    /// Maximum number of output tokens before stopping.
    static let maxOutputLength = 256

    enum T5Error: Error, LocalizedError {
        case encoderFailed(String)
        case decoderFailed(String)
        case modelLoadFailed(String)

        var errorDescription: String? {
            switch self {
            case .encoderFailed(let msg): return "T5 encoder failed: \(msg)"
            case .decoderFailed(let msg): return "T5 decoder failed: \(msg)"
            case .modelLoadFailed(let msg): return "T5 model load failed: \(msg)"
            }
        }
    }

    /// Initialize from model directory containing encoder_model.onnx, decoder_model.onnx, tokenizer.json.
    init(modelDir: String) throws {
        let encoderPath = "\(modelDir)/encoder_model.onnx"
        let decoderPath = "\(modelDir)/decoder_model.onnx"
        let tokenizerPath = "\(modelDir)/tokenizer.json"

        guard FileManager.default.fileExists(atPath: encoderPath) else {
            throw T5Error.modelLoadFailed("encoder_model.onnx not found in \(modelDir)")
        }
        guard FileManager.default.fileExists(atPath: decoderPath) else {
            throw T5Error.modelLoadFailed("decoder_model.onnx not found in \(modelDir)")
        }

        self.encoder = try ONNXSession(modelPath: encoderPath)
        self.decoder = try ONNXSession(modelPath: decoderPath)
        self.tokenizer = try T5Tokenizer(path: tokenizerPath)
    }

    // MARK: - TextPostProcessing

    func process(_ text: String) async throws -> String {
        guard !text.isEmpty else { return text }

        // Prepend T5 task prefix
        let inputText = Self.taskPrefix + text
        let inputIDs = tokenizer.encode(inputText)

        // Run encoder
        let encoderOutput = try runEncoder(inputIDs: inputIDs)

        // Run autoregressive greedy decoding
        let outputIDs = try greedyDecode(
            encoderHiddenStates: encoderOutput,
            encoderInputIDs: inputIDs
        )

        // Decode back to text
        let result = tokenizer.decode(outputIDs)
        return result.isEmpty ? text : result
    }

    // MARK: - Encoder

    private func runEncoder(inputIDs: [Int]) throws -> ONNXTensor {
        // Create input_ids tensor: [1, seq_len] of Int64
        let seqLen = inputIDs.count
        let int64IDs = inputIDs.map { Int64($0) }
        let inputData = int64IDs.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        let inputTensor = ONNXTensor(
            name: "input_ids",
            data: inputData,
            shape: [1, Int64(seqLen)],
            elementType: .int64
        )

        // Create attention_mask: all ones [1, seq_len]
        let maskValues = [Int64](repeating: 1, count: seqLen)
        let maskData = maskValues.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        let maskTensor = ONNXTensor(
            name: "attention_mask",
            data: maskData,
            shape: [1, Int64(seqLen)],
            elementType: .int64
        )

        let outputs = try encoder.run(
            inputs: [inputTensor, maskTensor],
            outputNames: ["last_hidden_state"]
        )

        guard let hiddenState = outputs.first else {
            throw T5Error.encoderFailed("no output from encoder")
        }
        return hiddenState
    }

    // MARK: - Decoder (greedy, no KV-cache)

    private func greedyDecode(
        encoderHiddenStates: ONNXTensor,
        encoderInputIDs: [Int]
    ) throws -> [Int] {
        var outputIDs: [Int] = [tokenizer.decoderStartTokenID]

        // Create encoder attention mask (all ones, same length as encoder input)
        let encoderSeqLen = encoderInputIDs.count
        let encoderMaskValues = [Int64](repeating: 1, count: encoderSeqLen)
        let encoderMaskData = encoderMaskValues.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        let encoderMaskTensor = ONNXTensor(
            name: "encoder_attention_mask",
            data: encoderMaskData,
            shape: [1, Int64(encoderSeqLen)],
            elementType: .int64
        )

        for _ in 0..<Self.maxOutputLength {
            // Prepare decoder input_ids: [1, current_output_length]
            let decoderSeqLen = outputIDs.count
            let decoderInputData = outputIDs.map { Int64($0) }.withUnsafeBufferPointer { buf in
                Data(buffer: buf)
            }
            let decoderInputTensor = ONNXTensor(
                name: "input_ids",
                data: decoderInputData,
                shape: [1, Int64(decoderSeqLen)],
                elementType: .int64
            )

            // Run decoder
            let decoderOutputs = try decoder.run(
                inputs: [decoderInputTensor, encoderHiddenStates, encoderMaskTensor],
                outputNames: ["logits"]
            )

            guard let logitsTensor = decoderOutputs.first else {
                throw T5Error.decoderFailed("no logits output")
            }

            // Extract last token's logits and take argmax
            let nextToken = argmaxLastToken(logitsTensor: logitsTensor, seqLen: decoderSeqLen)

            if nextToken == tokenizer.eosTokenID {
                break
            }
            outputIDs.append(nextToken)
        }

        return outputIDs
    }

    /// Extract logits for the last position and return argmax token ID.
    /// logitsTensor shape: [1, seq_len, vocab_size], dtype: float32
    private func argmaxLastToken(logitsTensor: ONNXTensor, seqLen: Int) -> Int {
        let vocabSize = Int(logitsTensor.shape[2])
        let lastTokenOffset = (seqLen - 1) * vocabSize

        return logitsTensor.data.withUnsafeBytes { rawBuf in
            let floats = rawBuf.bindMemory(to: Float.self)
            var bestIdx = 0
            var bestVal: Float = -.infinity
            for i in 0..<vocabSize {
                let val = floats[lastTokenOffset + i]
                if val > bestVal {
                    bestVal = val
                    bestIdx = i
                }
            }
            return bestIdx
        }
    }
}
