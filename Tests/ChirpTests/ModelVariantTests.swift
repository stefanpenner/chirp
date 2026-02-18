import Testing
import Foundation
@testable import Chirp

@Suite("ModelVariant")
struct ModelVariantTests {

    @Test("display name")
    func displayName() {
        #expect(ModelVariant.displayName == "Parakeet: 25 Euro Languages")
    }

    @Test("model dir name")
    func modelDirName() {
        #expect(ModelVariant.modelDirName == "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    }

    @Test("download URL")
    func downloadURL() {
        #expect(ModelVariant.downloadURL.absoluteString.contains("parakeet-tdt-0.6b-v3-int8"))
    }

    @Test("model type is nemo_transducer")
    func modelType() {
        #expect(ModelVariant.modelType == "nemo_transducer")
    }

    @Test("check file is encoder")
    func checkFile() {
        #expect(ModelVariant.checkFile == "encoder.int8.onnx")
    }

    @Test("size description")
    func sizeDescription() {
        #expect(ModelVariant.sizeDescription == "~465MB")
    }
}
