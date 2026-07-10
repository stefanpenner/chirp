// NoSpaceModeTests.swift — Pure no-space mode labels (dual of specs/NoSpaceMode.tla).

import Testing
@testable import Chirp

@Suite("NoSpaceMode")
struct NoSpaceModeTests {

    @Test("overlay label only when on")
    func overlayLabels() {
        #expect(NoSpaceMode.off.overlayLabel == nil)
        #expect(NoSpaceMode.on.overlayLabel == "no space")
    }

    @Test("isOn mirrors cases")
    func isOnFlag() {
        #expect(NoSpaceMode.off.isOn == false)
        #expect(NoSpaceMode.on.isOn == true)
    }
}
