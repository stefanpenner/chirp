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
    /// Prefer explicit `date` / `timeZone` from AppState (avoids process-global races in tests).
    /// Falls back to static providers when omitted (unit tests + default production).
    static func formatDate(_ date: Date? = nil, timeZone: TimeZone? = nil) -> String {
        let date = date ?? nowProvider()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone ?? timeZoneProvider()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    /// Local 12-hour time with dotted meridiem (e.g. "3:45 p.m.").
    /// Prefer explicit `date` / `timeZone` from AppState (avoids process-global races in tests).
    static func formatTime(_ date: Date? = nil, timeZone: TimeZone? = nil) -> String {
        let date = date ?? nowProvider()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone ?? timeZoneProvider()
        f.dateFormat = "h:mm a"
        let raw = f.string(from: date) // "3:45 PM"
        return raw
            .replacingOccurrences(of: "AM", with: "a.m.")
            .replacingOccurrences(of: "PM", with: "p.m.")
    }
}
