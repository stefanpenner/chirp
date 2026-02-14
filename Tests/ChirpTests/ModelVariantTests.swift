import Testing
import Foundation
@testable import Chirp

@Suite("ModelVariant")
struct ModelVariantTests {

    @Test("CaseIterable contains both cases")
    func allCases() {
        #expect(ModelVariant.allCases == [.tdt, .ctc])
    }

    @Test("TDT display name")
    func tdtDisplayName() {
        #expect(ModelVariant.tdt.displayName == "Parakeet TDT 0.6b (Best Quality)")
    }

    @Test("CTC display name")
    func ctcDisplayName() {
        #expect(ModelVariant.ctc.displayName == "Parakeet CTC 110m (Faster)")
    }

    @Test("TDT model dir name")
    func tdtModelDirName() {
        #expect(ModelVariant.tdt.modelDirName == "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
    }

    @Test("CTC model dir name")
    func ctcModelDirName() {
        #expect(ModelVariant.ctc.modelDirName == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")
    }

    @Test("TDT download URL")
    func tdtDownloadURL() {
        #expect(ModelVariant.tdt.downloadURL.absoluteString.contains("parakeet-tdt-0.6b-v2-int8"))
    }

    @Test("CTC download URL")
    func ctcDownloadURL() {
        #expect(ModelVariant.ctc.downloadURL.absoluteString.contains("parakeet_tdt_ctc_110m"))
    }

    @Test("TDT model type is nemo_transducer")
    func tdtModelType() {
        #expect(ModelVariant.tdt.modelType == "nemo_transducer")
    }

    @Test("CTC model type is nemo_ctc")
    func ctcModelType() {
        #expect(ModelVariant.ctc.modelType == "nemo_ctc")
    }

    @Test("TDT check file is encoder")
    func tdtCheckFile() {
        #expect(ModelVariant.tdt.checkFile == "encoder.int8.onnx")
    }

    @Test("CTC check file is model")
    func ctcCheckFile() {
        #expect(ModelVariant.ctc.checkFile == "model.int8.onnx")
    }

    @Test("TDT size description")
    func tdtSize() {
        #expect(ModelVariant.tdt.sizeDescription == "~630MB")
    }

    @Test("CTC size description")
    func ctcSize() {
        #expect(ModelVariant.ctc.sizeDescription == "~126MB")
    }

    @Test("saved round-trips through UserDefaults")
    func savedRoundTrip() {
        let original = ModelVariant.saved
        defer { ModelVariant.saved = original }

        ModelVariant.saved = .ctc
        #expect(ModelVariant.saved == .ctc)

        ModelVariant.saved = .tdt
        #expect(ModelVariant.saved == .tdt)
    }
}
