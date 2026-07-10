// InsertStampTests.swift — Date/time stamp formatters (pinned clock).

import Testing
import Foundation
@testable import Chirp

// Serialized: static nowProvider / timeZoneProvider are process-global.
@Suite("InsertStamp", .serialized)
struct InsertStampTests {

    @Test("formatDate matches SpokenDateITN absolute style")
    func formatDate() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10
        comps.hour = 15; comps.minute = 45
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        InsertStamp.nowProvider = { pinned }
        InsertStamp.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        defer { InsertStamp.resetClock() }

        #expect(InsertStamp.formatDate() == "July 10, 2026")
        #expect(InsertStamp.formatDate(pinned) == "July 10, 2026")
        // Same style as SpokenDateITN
        SpokenDateITN.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        defer { SpokenDateITN.resetTimeZone() }
        #expect(InsertStamp.formatDate(pinned) == SpokenDateITN.formatAbsoluteDate(pinned))
    }

    @Test("formatTime is local 12h with a.m./p.m.")
    func formatTime() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10
        comps.hour = 15; comps.minute = 45
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let pinned = cal.date(from: comps)!
        InsertStamp.nowProvider = { pinned }
        InsertStamp.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        defer { InsertStamp.resetClock() }

        #expect(InsertStamp.formatTime() == "3:45 p.m.")
        #expect(InsertStamp.formatTime(pinned) == "3:45 p.m.")
    }

    @Test("formatTime morning and noon/midnight edges")
    func formatTimeEdges() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        InsertStamp.timeZoneProvider = { TimeZone(identifier: "UTC")! }
        defer { InsertStamp.resetClock() }

        var am = DateComponents()
        am.year = 2026; am.month = 1; am.day = 1
        am.hour = 9; am.minute = 5
        #expect(InsertStamp.formatTime(cal.date(from: am)!) == "9:05 a.m.")

        var noon = DateComponents()
        noon.year = 2026; noon.month = 1; noon.day = 1
        noon.hour = 12; noon.minute = 0
        #expect(InsertStamp.formatTime(cal.date(from: noon)!) == "12:00 p.m.")

        var midnight = DateComponents()
        midnight.year = 2026; midnight.month = 1; midnight.day = 1
        midnight.hour = 0; midnight.minute = 0
        #expect(InsertStamp.formatTime(cal.date(from: midnight)!) == "12:00 a.m.")
    }
}
