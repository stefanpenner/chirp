// ModelVariant.swift — Available speech recognition model variants.
// Holds download URLs, directory names, and size metadata for each model.
// Used by ModelManager (download/locate) and Transcriber (model configuration).

import Foundation

public enum ModelVariant: String, CaseIterable, Sendable {
    case tdt              // Parakeet TDT 0.6b v2 (English)
    case tdtMultilingual  // Parakeet TDT 0.6b v3 (25 European languages)

    public var displayName: String {
        switch self {
        case .tdt: return "Parakeet TDT English"
        case .tdtMultilingual: return "Parakeet TDT Multilingual"
        }
    }

    var modelDirName: String {
        switch self {
        case .tdt: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
        case .tdtMultilingual: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
        }
    }

    var downloadURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelDirName).tar.bz2")!
    }

    public var sizeDescription: String {
        switch self {
        case .tdt: return "~460MB"
        case .tdtMultilingual: return "~460MB"
        }
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

    public var languageDescription: String {
        switch self {
        case .tdt: return "English"
        case .tdtMultilingual: return "25 European languages"
        }
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
