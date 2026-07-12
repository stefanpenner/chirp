// SpokenDateITNTests.swift — Light spoken date ITN.

import Testing
import Foundation
@testable import Chirp

// Serialized: static nowProvider / timeZoneProvider are process-global.
@Suite("SpokenDateITN", .serialized)
struct SpokenDateITNTests {

    @Test("month and day")
    func monthDay() {
        #expect(SpokenDateITN.apply("march fifth") == "March 5")
        #expect(SpokenDateITN.apply("july the fifteenth") == "July 15")
        #expect(SpokenDateITN.apply("on april third we meet") == "on April 3 we meet")
    }

    /// Day-first spoken form: "the fifth of march" (common free dictation).
    @Test("day of month (day-first)")
    func dayOfMonth() {
        #expect(SpokenDateITN.apply("the fifth of march") == "March 5")
        #expect(SpokenDateITN.apply("fifth of march") == "March 5")
        #expect(SpokenDateITN.apply("the fifteenth of july") == "July 15")
        #expect(SpokenDateITN.apply("the 15th of july") == "July 15")
        #expect(SpokenDateITN.apply("twenty first of march") == "March 21")
        #expect(
            SpokenDateITN.apply("the fifth of march twenty twenty four")
                == "March 5, 2024"
        )
        #expect(
            SpokenDateITN.apply("meeting on the fifteenth of july twenty twenty six")
                == "meeting on July 15, 2026"
        )
        // Guards: not a date
        #expect(SpokenDateITN.apply("the end of march") == "the end of march")
        #expect(SpokenDateITN.apply("the first of all") == "the first of all")
        #expect(SpokenDateITN.apply("a lot of may") == "a lot of may")
    }

    /// ASR often yields European order "5 March" (ITN audio dump).
    @Test("digit day then month (European ASR form)")
    func digitDayThenMonth() {
        #expect(SpokenDateITN.apply("5 March") == "March 5")
        #expect(SpokenDateITN.apply("15 July") == "July 15")
        #expect(SpokenDateITN.apply("due 5 March") == "due March 5")
        #expect(SpokenDateITN.apply("5 March 2024") == "March 5, 2024")
        // Guards
        #expect(SpokenDateITN.apply("5 birds") == "5 birds")
        #expect(SpokenDateITN.apply("march 5") == "March 5") // month-first still works
    }

    @Test("month day after ordinal ITN digit form")
    func monthDayDigit() {
        #expect(SpokenDateITN.apply("march 15th") == "March 15")
        #expect(SpokenDateITN.apply("march 5") == "March 5")
    }

    @Test("month day year")
    func monthDayYear() {
        #expect(SpokenDateITN.apply("march fifth twenty twenty four") == "March 5, 2024")
        #expect(SpokenDateITN.apply("july 15th twenty twenty six") == "July 15, 2026")
        #expect(SpokenDateITN.apply("october first two thousand twenty") == "October 1, 2020")
        #expect(SpokenDateITN.apply("march fifteenth twenty twenty four") == "March 15, 2024")
        #expect(
            SpokenDateITN.apply("meeting on march fifteenth twenty twenty four")
                == "meeting on March 15, 2024"
        )
    }

    @Test("standalone years")
    func years() {
        #expect(SpokenDateITN.apply("in twenty twenty six") == "in 2026")
        #expect(SpokenDateITN.apply("since twenty nineteen") == "since 2019")
        #expect(SpokenDateITN.apply("two thousand twenty four") == "2024")
    }

    @Test("nineteen-hundreds years")
    func years1900s() {
        #expect(SpokenDateITN.apply("in nineteen ninety nine") == "in 1999")
        #expect(SpokenDateITN.apply("since nineteen eighty four") == "since 1984")
        #expect(SpokenDateITN.apply("nineteen ninety") == "1990")
        #expect(SpokenDateITN.apply("march fifth nineteen ninety five") == "March 5, 1995")
        #expect(SpokenDateITN.apply("the fifth of march nineteen eighty four") == "March 5, 1984")
        // Guards: incomplete year phrase stays words
        #expect(SpokenDateITN.apply("nineteen birds") == "nineteen birds")
        #expect(SpokenDateITN.apply("the first of all") == "the first of all")
    }

    @Test("does not rewrite bare month or may I")
    func safeGuards() {
        #expect(SpokenDateITN.apply("march on the capital") == "march on the capital")
        #expect(SpokenDateITN.apply("may I help") == "may I help")
        #expect(SpokenDateITN.apply("april showers") == "april showers")
    }

    @Test("twenty first as day of month")
    func compoundDay() {
        #expect(SpokenDateITN.apply("march twenty first") == "March 21")
        #expect(SpokenDateITN.apply("may thirty first") == "May 31")
    }

    @Test("weekday capitalization")
    func weekdays() {
        #expect(SpokenDateITN.apply("meet on monday") == "meet on Monday")
        #expect(SpokenDateITN.apply("sunday") == "Sunday")
    }

    @Test("relative days resolve with injectable clock")
    func relativeDays() {
        // Pin clock via args (no process-global race): Wednesday 2026-07-08 UTC
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 8
        comps.hour = 15
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "UTC")!
        cal.timeZone = tz
        let pinned = cal.date(from: comps)!

        #expect(SpokenDateITN.apply("today", now: pinned, timeZone: tz) == "July 8, 2026")
        #expect(SpokenDateITN.apply("tomorrow", now: pinned, timeZone: tz) == "July 9, 2026")
        #expect(SpokenDateITN.apply("yesterday", now: pinned, timeZone: tz) == "July 7, 2026")
        #expect(
            SpokenDateITN.apply("due tomorrow please", now: pinned, timeZone: tz)
                == "due July 9, 2026 please"
        )
    }

    @Test("next this last weekday")
    func relativeWeekdays() {
        // Wednesday 2026-07-08 — explicit clock args (parallel-safe)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 8
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "UTC")!
        cal.timeZone = tz
        let pinned = cal.date(from: comps)!

        // Next Friday = July 10
        #expect(SpokenDateITN.apply("next friday", now: pinned, timeZone: tz) == "July 10, 2026")
        // This Wednesday = today
        #expect(SpokenDateITN.apply("this wednesday", now: pinned, timeZone: tz) == "July 8, 2026")
        // Last Monday = July 6
        #expect(SpokenDateITN.apply("last monday", now: pinned, timeZone: tz) == "July 6, 2026")
        // Next Monday = July 13 (not today)
        #expect(
            SpokenDateITN.apply("meet next monday", now: pinned, timeZone: tz)
                == "meet July 13, 2026"
        )
    }
}

@Suite("TextPostProcessor date ITN")
struct TextPostProcessorDateITNTests {

    @Test("full pipeline month day year")
    func integrated() {
        let r = TextPostProcessor.process("meeting on march fifteenth twenty twenty four")
        #expect(r.contains("March 15"), "got \(r)")
        #expect(r.contains("2024"), "got \(r)")
        let dayFirst = TextPostProcessor.process("due the fifth of march twenty twenty four")
        #expect(dayFirst.contains("March 5"), "got \(dayFirst)")
        #expect(dayFirst.contains("2024"), "got \(dayFirst)")
        let y19 = TextPostProcessor.process("born in nineteen ninety nine")
        #expect(y19.contains("1999"), "got \(y19)")
    }

    @Test("keeps twenty twenty for year (no stutter collapse)")
    func keepsYearRepetition() {
        // "the the" collapses; "twenty twenty" must not (year 2020+)
        #expect(TextPostProcessor.process("the the cat") == "the cat")
        let y = TextPostProcessor.process("in twenty twenty six")
        #expect(y.contains("2026"), "got \(y)")
    }

    @Test("bare one more thing still safe")
    func bareOne() {
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
    }
}
