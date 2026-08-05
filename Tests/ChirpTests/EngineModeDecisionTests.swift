// EngineModeDecisionTests.swift — Dual-test pure gates against EngineMode.tla.

import Testing
@testable import Chirp

@Suite("EngineModeDecision (TLA+ dual)")
struct EngineModeDecisionTests {

    @Test("offline and cloud always resolve as-is")
    func offlineCloudAlways() {
        #expect(EngineModeDecision.resolve(desired: .offline, systemAvailable: false) == .offline)
        #expect(EngineModeDecision.resolve(desired: .offline, systemAvailable: true) == .offline)
        #expect(EngineModeDecision.resolve(desired: .cloud, systemAvailable: false) == .cloud)
        #expect(EngineModeDecision.resolve(desired: .cloud, systemAvailable: true) == .cloud)
    }

    @Test("systemSpeech falls back to offline when unavailable")
    func systemFallback() {
        #expect(
            EngineModeDecision.resolve(desired: .systemSpeech, systemAvailable: false) == .offline
        )
        #expect(
            EngineModeDecision.resolve(desired: .systemSpeech, systemAvailable: true) == .systemSpeech
        )
    }

    @Test("fluidAvailable reserved — no mode yet; dual stays offline default")
    func fluidReserved() {
        // TLA models fluid → offline when fluidOk=FALSE; product has no enum case yet.
        #expect(EngineModeDecision.resolve(desired: .offline, systemAvailable: true, fluidAvailable: true) == .offline)
        #expect(EngineModeDecision.isLegalActive(.offline, systemAvailable: false, fluidAvailable: false))
    }

    @Test("defer apply only while session active")
    func deferApply() {
        #expect(EngineModeDecision.shouldDeferApply(sessionActive: true))
        #expect(!EngineModeDecision.shouldDeferApply(sessionActive: false))
        #expect(EngineModeDecision.canApplyResolved(sessionActive: false, needsRebuild: true))
        #expect(!EngineModeDecision.canApplyResolved(sessionActive: true, needsRebuild: true))
        #expect(!EngineModeDecision.canApplyResolved(sessionActive: false, needsRebuild: false))
    }

    @Test("legal active: system requires availability")
    func legalActive() {
        #expect(EngineModeDecision.isLegalActive(.offline, systemAvailable: false))
        #expect(EngineModeDecision.isLegalActive(.cloud, systemAvailable: false))
        #expect(EngineModeDecision.isLegalActive(.systemSpeech, systemAvailable: true))
        #expect(!EngineModeDecision.isLegalActive(.systemSpeech, systemAvailable: false))
    }
}
