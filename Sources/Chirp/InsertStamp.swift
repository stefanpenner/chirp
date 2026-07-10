// InsertStamp.swift — Format current date/time for spoken "insert date" / "insert time".
// Pure formatters; clock and timezone injectable for tests.

import Foundation

enum InsertStamp {
    /// Injectable clock (tests pin this; production uses `Date()`).
    /// `nonisolated(unsafe)` — tests set on the test thread only.
    nonisolated(unsafe) static var nowProvider: () -> Date = { Date() }

    /// Injectable timezone (tests use UTC; production uses the user local zone).
    nonisolated(unsafe) static var timeZoneProvider: () -> TimeZone = { .current }

    /// Reset clock and timezone to system defaults.
    static func resetClock() {
        nowProvider = { Date() }
        timeZoneProvider = { .current }
    }

    /// Absolute date, same style as `SpokenDateITN.formatAbsoluteDate` (e.g. "July 10, 2026").
    static func formatDate(_ date: Date = nowProvider()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZoneProvider()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    /// Local 12-hour time with dotted meridiem (e.g. "3:45 p.m.").
    static func formatTime(_ date: Date = nowProvider()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZoneProvider()
        f.dateFormat = "h:mm a"
        let raw = f.string(from: date) // "3:45 PM"
        return raw
            .replacingOccurrences(of: "AM", with: "a.m.")
            .replacingOccurrences(of: "PM", with: "p.m.")
    }
}
