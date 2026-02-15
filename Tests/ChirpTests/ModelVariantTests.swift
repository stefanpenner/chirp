import Testing
import Foundation
@testable import Chirp

@Suite("ModelVariant")
struct ModelVariantTests {

    @Test("CaseIterable contains tdt")
    func allCases() {
        #expect(ModelVariant.allCases == [.tdt])
    }

    @Test("TDT display name")
    func tdtDisplayName() {
        #expect(ModelVariant.tdt.displayName == "Parakeet TDT 0.6b")
    }

    @Test("TDT model dir name")
    func tdtModelDirName() {
        #expect(ModelVariant.tdt.modelDirName == "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
    }

    @Test("TDT download URL")
    func tdtDownloadURL() {
        #expect(ModelVariant.tdt.downloadURL.absoluteString.contains("parakeet-tdt-0.6b-v2-int8"))
    }

    @Test("TDT model type is nemo_transducer")
    func tdtModelType() {
        #expect(ModelVariant.tdt.modelType == "nemo_transducer")
    }

    @Test("TDT check file is encoder")
    func tdtCheckFile() {
        #expect(ModelVariant.tdt.checkFile == "encoder.int8.onnx")
    }

    @Test("TDT size description")
    func tdtSize() {
        #expect(ModelVariant.tdt.sizeDescription == "~630MB")
    }

    @Test("saved round-trips through UserDefaults")
    func savedRoundTrip() {
        let original = ModelVariant.saved
        defer { ModelVariant.saved = original }

        ModelVariant.saved = .tdt
        #expect(ModelVariant.saved == .tdt)
    }
}
