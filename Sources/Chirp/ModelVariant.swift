// ModelVariant.swift — Speech recognition model configuration.
// Holds download URL, directory name, and metadata for the model.
// Used by ModelManager (download/locate) and Transcriber (model configuration).

import Foundation

enum ModelVariant {
    static let displayName = "Parakeet: 25 Euro Languages"
    static let modelDirName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    static let downloadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelDirName).tar.bz2")!
    static let sizeDescription = "~465MB"
    static let infoURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models")!
    static let modelType = "nemo_transducer"
    static let checkFile = "encoder.int8.onnx"
}
