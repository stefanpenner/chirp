// ModelVariant.swift — Available speech recognition model variants.
// Holds download URLs, directory names, and size metadata for each model.
// Used by ModelManager (download/locate) and Transcriber (model configuration).

import Foundation

public enum ModelVariant: String, CaseIterable, Sendable {
    case tdt   // Parakeet TDT 0.6b v2 (3-file transducer, best quality)

    public var displayName: String {
        "Parakeet TDT 0.6b"
    }

    var modelDirName: String {
        "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
    }

    var downloadURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelDirName).tar.bz2")!
    }

    var sizeDescription: String {
        "~630MB"
    }

    var infoURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models")!
    }

    /// sherpa-onnx model_type string for recognizer config.
    var modelType: String {
        "nemo_transducer"
    }

    /// File to check when determining if a model is already downloaded.
    var checkFile: String {
        "encoder.int8.onnx"
    }

    // MARK: - Persistence

    static let defaultsKey = "selectedModelVariant"

    static var saved: ModelVariant {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let variant = ModelVariant(rawValue: raw) else {
                return .tdt
            }
            return variant
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
