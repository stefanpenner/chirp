// SpokenDateITN.swift — Light inverse text normalization for spoken dates.
// Runs in the light-ITN pipeline (before/after cardinals as needed).
//
// Examples:
//   "march fifth" → "March 5"
//   "july 15th twenty twenty four" → "July 15, 2024"
//   "in twenty twenty six" → "in 2026"
//   "tomorrow" / "next monday" → absolute dates (clock injectable for tests)
//
// Safe: month alone ("march on") is not rewritten; needs a day or year span.

import Foundation

enum SpokenDateITN {
    /// Injectable clock for relative dates (tests pin this; production uses `Date()`).
    /// `nonisolated(unsafe)` — tests set on the test thread only.
    nonisolated(unsafe) static var nowProvider: () -> Date = { Date() }

    /// Reset clock to system time (call after tests that override).
    static func resetClock() {
        nowProvider = { Date() }
    }
    private static let months: [String: String] = [
        "january": "January", "february": "February", "march": "March",
        "april": "April", "may": "May", "june": "June",
        "july": "July", "august": "August", "september": "September",
        "october": "October", "november": "November", "december": "December",
    ]

    private static let dayWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20,
        "twenty": 20, // combined with first-ninth below
        "thirtieth": 30, "thirty": 30,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    private static let dayUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let yearUnits: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let weekdays: [String: String] = [
        "monday": "Monday", "tuesday": "Tuesday", "wednesday": "Wednesday",
        "thursday": "Thursday", "friday": "Friday", "saturday": "Saturday",
        "sunday": "Sunday",
    ]

    /// Calendar weekday: Sunday=1 … Saturday=7 (Calendar.Component.weekday).
    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// Rewrite spoken month/day(/year), relative dates, years, and weekdays.
    static func apply(_ text: String) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return text }
        let now = nowProvider()

        var out: [String] = []
        var i = 0
        while i < parts.count {
            let core = normalize(parts[i])

            // Month + optional "the" + day + optional year
            if let monthName = months[core] {
                if let (formatted, consumed) = parseMonthDate(parts: parts, start: i, monthName: monthName) {
                    out.append(formatted)
                    i += consumed
                    continue
                }
            }

            // next/this/last + weekday → absolute date
            if (core == "next" || core == "this" || core == "last"),
               i + 1 < parts.count,
               let wd = weekdayNumbers[normalize(parts[i + 1])] {
                let date = relativeWeekday(wd, mode: core, from: now)
                let trailing = trailingPunct(parts[i + 1])
                out.append(formatAbsoluteDate(date) + trailing)
                i += 2
                continue
            }

            // today / tomorrow / yesterday → absolute date
            if core == "today" || core == "tomorrow" || core == "yesterday" {
                let date = relativeDay(core, from: now)
                let trailing = trailingPunct(parts[i])
                out.append(formatAbsoluteDate(date) + trailing)
                i += 1
                continue
            }

            // Standalone year: "twenty twenty four" / "two thousand twenty six"
            if let (year, consumed) = parseYear(parts: parts, start: i), consumed >= 2 {
                let trailing = trailingPunct(parts[i + consumed - 1])
                out.append(String(year) + trailing)
                i += consumed
                continue
            }

            // Weekday capitalization: monday → Monday (preserves trailing punct)
            if let day = weekdays[core] {
                out.append(day + trailingPunct(parts[i]))
                i += 1
                continue
            }

            out.append(parts[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: - Relative dates

    static func formatAbsoluteDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    static func relativeDay(_ word: String, from now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.startOfDay(for: now)
        switch word {
        case "today": return start
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: start) ?? start
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: start) ?? start
        default: return start
        }
    }

    /// next = strictly after today; this = today if match else next; last = strictly before today.
    static func relativeWeekday(_ weekday: Int, mode: String, from now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.startOfDay(for: now)
        let todayWD = cal.component(.weekday, from: start)

        switch mode {
        case "this":
            if todayWD == weekday { return start }
            fallthrough
        case "next":
            var delta = weekday - todayWD
            if delta <= 0 { delta += 7 }
            return cal.date(byAdding: .day, value: delta, to: start) ?? start
        case "last":
            var delta = todayWD - weekday
            if delta <= 0 { delta += 7 }
            return cal.date(byAdding: .day, value: -delta, to: start) ?? start
        default:
            return start
        }
    }

    // MARK: - Month + day (+ year)

    private static func parseMonthDate(
        parts: [String],
        start: Int,
        monthName: String
    ) -> (String, Int)? {
        var j = start + 1
        guard j < parts.count else { return nil }

        // Optional "the"
        if normalize(parts[j]) == "the" {
            j += 1
            guard j < parts.count else { return nil }
        }

        guard let (day, dayConsumed) = parseDay(parts: parts, start: j) else {
            return nil
        }
        j += dayConsumed

        var year: Int?
        if j < parts.count, let (y, yc) = parseYear(parts: parts, start: j) {
            year = y
            j += yc
        }

        let trailing = trailingPunct(parts[j - 1])
        var formatted = "\(monthName) \(day)"
        if let y = year {
            formatted += ", \(y)"
        }
        formatted += trailing
        return (formatted, j - start)
    }

    /// Parse a calendar day 1…31 from words or "15th" / "5".
    private static func parseDay(parts: [String], start: Int) -> (Int, Int)? {
        guard start < parts.count else { return nil }
        let raw = parts[start]
        let core = normalize(raw)

        // Already digit form from prior ITN: "15th", "5", "15"
        if let d = parseDigitDay(core) {
            return (d, 1)
        }

        // twenty first / thirty first
        if (core == "twenty" || core == "thirty"), start + 1 < parts.count {
            let u = normalize(parts[start + 1])
            if let unit = dayUnits[u] {
                let day = (core == "twenty" ? 20 : 30) + unit
                if day >= 1 && day <= 31 {
                    return (day, 2)
                }
            }
        }

        // Single day word: fifth, fifteenth, …
        if let d = dayWords[core], d >= 1, d <= 31 {
            // "twenty" alone is not a day without unit
            if core == "twenty" || core == "thirty" { return nil }
            return (d, 1)
        }

        return nil
    }

    private static func parseDigitDay(_ core: String) -> Int? {
        // 15th, 1st, 2nd, 3rd, 4th
        let stripped = core.replacingOccurrences(
            of: #"(st|nd|rd|th)$"#,
            with: "",
            options: .regularExpression
        )
        guard let n = Int(stripped), n >= 1, n <= 31 else { return nil }
        return n
    }

    // MARK: - Year

    /// Parse spoken year at `start`. Returns (year, token count).
    static func parseYear(parts: [String], start: Int) -> (Int, Int)? {
        guard start < parts.count else { return nil }
        let c0 = normalize(parts[start])

        // Already a 4-digit year
        if let y = Int(c0), y >= 1900, y <= 2100 {
            return (y, 1)
        }

        // two thousand (and)? N
        if c0 == "two", start + 1 < parts.count, normalize(parts[start + 1]) == "thousand" {
            var j = start + 2
            if j < parts.count, normalize(parts[j]) == "and" { j += 1 }
            if j < parts.count, let rest = parseYearRest(parts: parts, start: j) {
                return (2000 + rest.value, rest.consumed + (j - start))
            }
            // bare "two thousand"
            return (2000, 2)
        }

        // twenty twenty / twenty twenty four / twenty nineteen
        if c0 == "twenty", start + 1 < parts.count {
            let c1 = normalize(parts[start + 1])
            // twenty twenty [unit]?
            if c1 == "twenty" {
                if start + 2 < parts.count, let u = yearUnits[normalize(parts[start + 2])], u < 10 {
                    return (2020 + u, 3)
                }
                return (2020, 2)
            }
            // twenty nineteen, twenty eighteen, …
            if let decadePart = yearUnits[c1], decadePart >= 10, decadePart < 20 {
                return (2000 + decadePart, 2) // twenty nineteen → 2019
            }
            // twenty thirty → 2030, twenty thirty five → 2035
            if let t = yearUnits[c1], t >= 20, t <= 90, t % 10 == 0 {
                if start + 2 < parts.count, let u = yearUnits[normalize(parts[start + 2])], u < 10 {
                    return (2000 + t + u, 3)
                }
                return (2000 + t, 2)
            }
        }

        return nil
    }

    private struct YearRest {
        let value: Int
        let consumed: Int
    }

    private static func parseYearRest(parts: [String], start: Int) -> YearRest? {
        guard start < parts.count else { return nil }
        let c0 = normalize(parts[start])
        if let u = yearUnits[c0] {
            if u >= 20, u % 10 == 0, start + 1 < parts.count,
               let u2 = yearUnits[normalize(parts[start + 1])], u2 < 10 {
                return YearRest(value: u + u2, consumed: 2)
            }
            return YearRest(value: u, consumed: 1)
        }
        return nil
    }

    // MARK: - Helpers

    private static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func trailingPunct(_ token: String) -> String {
        var suffix = ""
        for ch in token.reversed() {
            if ch.isPunctuation {
                suffix = String(ch) + suffix
            } else {
                break
            }
        }
        return suffix
    }
}
