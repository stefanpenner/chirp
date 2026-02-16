import Testing
import Foundation
@testable import Chirp

@Suite("ModelVariant", .serialized)
struct ModelVariantTests {

    @Test("CaseIterable contains tdt and tdtMultilingual")
    func allCases() {
        #expect(ModelVariant.allCases == [.tdt, .tdtMultilingual])
    }

    // MARK: - TDT (English)

    @Test("TDT display name")
    func tdtDisplayName() {
        #expect(ModelVariant.tdt.displayName == "Parakeet: English Only")
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
        #expect(ModelVariant.tdt.sizeDescription == "~460MB")
    }

    @Test("TDT language description")
    func tdtLanguage() {
        #expect(ModelVariant.tdt.languageDescription == "English")
    }

    // MARK: - TDT Multilingual

    @Test("Multilingual display name")
    func multilingualDisplayName() {
        #expect(ModelVariant.tdtMultilingual.displayName == "Parakeet: 25 Euro Languages")
    }

    @Test("Multilingual model dir name")
    func multilingualModelDirName() {
        #expect(ModelVariant.tdtMultilingual.modelDirName == "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    }

    @Test("Multilingual download URL")
    func multilingualDownloadURL() {
        #expect(ModelVariant.tdtMultilingual.downloadURL.absoluteString.contains("parakeet-tdt-0.6b-v3-int8"))
    }

    @Test("Multilingual model type is nemo_transducer")
    func multilingualModelType() {
        #expect(ModelVariant.tdtMultilingual.modelType == "nemo_transducer")
    }

    @Test("Multilingual check file is encoder")
    func multilingualCheckFile() {
        #expect(ModelVariant.tdtMultilingual.checkFile == "encoder.int8.onnx")
    }

    @Test("Multilingual size description")
    func multilingualSize() {
        #expect(ModelVariant.tdtMultilingual.sizeDescription == "~465MB")
    }

    @Test("Multilingual language description")
    func multilingualLanguage() {
        #expect(ModelVariant.tdtMultilingual.languageDescription == "25 European languages")
    }

    // MARK: - Persistence

    @Test("saved round-trips through UserDefaults for tdt")
    func savedRoundTripTdt() {
        let original = ModelVariant.saved
        defer { ModelVariant.saved = original }

        ModelVariant.saved = .tdt
        #expect(ModelVariant.saved == .tdt)
    }

    @Test("saved round-trips through UserDefaults for tdtMultilingual")
    func savedRoundTripMultilingual() {
        let original = ModelVariant.saved
        defer { ModelVariant.saved = original }

        ModelVariant.saved = .tdtMultilingual
        #expect(ModelVariant.saved == .tdtMultilingual)
    }
}
