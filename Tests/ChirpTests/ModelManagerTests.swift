import Testing
import Foundation
@testable import Chirp

@Suite("ModelManager")
struct ModelManagerTests {

    @Test("installBase points to Application Support/Chirp/models")
    func installBase() {
        let base = ModelManager.installBase
        #expect(base.contains("Application Support/Chirp/models"))
    }

    @Test("findExisting returns nil when VAD not in bundle")
    func findExistingNilWithoutBundle() {
        // Without the VAD bundled (test runner has no bundle resources),
        // findExisting should return nil but not crash
        let result = ModelManager.findExisting()
        #expect(result == nil)
    }

    @Test("CHIRP_MODEL_DIR ignored when check file absent")
    func envVarIgnoredWithoutCheckFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChirpEnvTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tmpDir)
            unsetenv("CHIRP_MODEL_DIR")
        }

        // Point env var at directory with no check file
        setenv("CHIRP_MODEL_DIR", tmpDir.path, 1)

        let result = ModelManager.findExisting()
        // Should not use the env dir since check file is absent
        #expect(result == nil || result?.modelDir != tmpDir.path)
    }
}
