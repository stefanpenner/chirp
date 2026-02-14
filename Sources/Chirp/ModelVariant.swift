import Foundation

enum ModelVariant: String, CaseIterable {
    case tdt   // Parakeet TDT 0.6b v2 (3-file transducer, best quality)
    case ctc   // Parakeet TDT-CTC 110m (single file, faster/smaller)

    var displayName: String {
        switch self {
        case .tdt: return "Parakeet TDT 0.6b (Best Quality)"
        case .ctc: return "Parakeet CTC 110m (Faster)"
        }
    }

    var modelDirName: String {
        switch self {
        case .tdt: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
        case .ctc: return "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"
        }
    }

    var downloadURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelDirName).tar.bz2")!
    }

    var sizeDescription: String {
        switch self {
        case .tdt: return "~630MB"
        case .ctc: return "~126MB"
        }
    }

    /// sherpa-onnx model_type string
    var modelType: String {
        switch self {
        case .tdt: return "nemo_transducer"
        case .ctc: return "nemo_ctc"
        }
    }

    /// The file to check for to determine if model is downloaded
    var checkFile: String {
        switch self {
        case .tdt: return "encoder.int8.onnx"
        case .ctc: return "model.int8.onnx"
        }
    }

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
