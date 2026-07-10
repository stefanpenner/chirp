// FormatSettingsTests.swift — Auto-format toggles gate ITN features.

import Testing
import Foundation
@testable import Chirp

@Suite("FormatSettings", .serialized)
struct FormatSettingsTests {

    @Test("disabling numbered lists leaves commands as words")
    func numberedListsOff() {
        FormatSettings.testExpandNumberedLists = false
        defer { FormatSettings.resetTestOverrides() }
        TextPostProcessor.resetSessionFormatState()
        let r = TextPostProcessor.process("number one milk next number eggs")
        #expect(r.contains("number one") || r.lowercased().contains("number"))
        #expect(!r.contains("1. "))
    }

    @Test("disabling relative dates leaves tomorrow as word")
    func relativeDatesOff() {
        FormatSettings.testExpandRelativeDates = false
        defer { FormatSettings.resetTestOverrides() }
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 8
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        SpokenDateITN.nowProvider = { pinned }
        SpokenDateITN.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        defer {
            SpokenDateITN.resetClock()
            SpokenDateITN.resetTimeZone()
        }
        let r = SpokenDateITN.apply("due tomorrow")
        #expect(r == "due tomorrow")
        // Absolute calendar dates still work
        #expect(SpokenDateITN.apply("march fifth") == "March 5")
    }

    @Test("disabling bullets leaves bullet point as words")
    func bulletsOff() {
        FormatSettings.testExpandBullets = false
        defer { FormatSettings.resetTestOverrides() }
        let r = TextPostProcessor.process("buy milk bullet point eggs")
        #expect(r.lowercased().contains("bullet"))
        #expect(!r.contains("•"))
    }
}
