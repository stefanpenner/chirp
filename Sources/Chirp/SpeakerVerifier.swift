// SpeakerVerifier.swift — ECAPA-TDNN speaker embedding actor.
// Wraps an ONNXSession for speaker verification inference.
// Extracts 192-dim embeddings, enrolls a reference, and verifies segments.

import Foundation

actor SpeakerVerifier: SpeakerVerifying {
    private var session: ONNXSession?
    private var referenceEmbedding: [Float]?

    var hasReference: Bool {
        referenceEmbedding != nil
    }

    func loadModel(path: String) throws {
        session = try ONNXSession(modelPath: path)
        Log.speaker.info("Speaker verification model loaded")
    }

    func extractEmbedding(samples: [Float]) throws -> [Float] {
        guard let session else {
            throw SpeakerVerifierError.modelNotLoaded
        }

        let inputData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let inputTensor = ONNXTensor(
            name: "input",
            data: inputData,
            shape: [1, Int64(samples.count)],
            elementType: .float32
        )

        let outputs = try session.run(inputs: [inputTensor], outputNames: ["output"])
        guard let output = outputs.first else {
            throw SpeakerVerifierError.noOutput
        }

        let floatCount = output.data.count / MemoryLayout<Float>.size
        let embedding = output.data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
        }

        return Self.l2Normalize(embedding)
    }

    func enroll(embeddings: [[Float]]) {
        guard !embeddings.isEmpty else { return }
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<min(dim, emb.count) {
                avg[i] += emb[i]
            }
        }
        let n = Float(embeddings.count)
        for i in 0..<dim { avg[i] /= n }
        referenceEmbedding = Self.l2Normalize(avg)
        Log.speaker.info("Enrolled speaker with \(embeddings.count) embeddings")
    }

    func setReferenceEmbedding(_ embedding: [Float]?) {
        referenceEmbedding = embedding
    }

    func verify(samples: [Float]) throws -> Float {
        guard let ref = referenceEmbedding else {
            throw SpeakerVerifierError.noReference
        }
        let emb = try extractEmbedding(samples: samples)
        return Self.cosineSimilarity(emb, ref)
    }

    func isMatch(samples: [Float], threshold: Float) throws -> Bool {
        try verify(samples: samples) >= threshold
    }

    // MARK: - Static helpers

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    enum SpeakerVerifierError: LocalizedError {
        case modelNotLoaded
        case noOutput
        case noReference

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Speaker verification model not loaded"
            case .noOutput: return "No output from speaker verification model"
            case .noReference: return "No reference embedding enrolled"
            }
        }
    }
}
