// SpokenDateITNTests.swift — Light spoken date ITN.

import Testing
@testable import Chirp

@Suite("SpokenDateITN")
struct SpokenDateITNTests {

    @Test("month and day")
    func monthDay() {
        #expect(SpokenDateITN.apply("march fifth") == "March 5")
        #expect(SpokenDateITN.apply("july the fifteenth") == "July 15")
        #expect(SpokenDateITN.apply("on april third we meet") == "on April 3 we meet")
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
}

@Suite("TextPostProcessor date ITN")
struct TextPostProcessorDateITNTests {

    @Test("full pipeline month day year")
    func integrated() {
        let r = TextPostProcessor.process("meeting on march fifteenth twenty twenty four")
        #expect(r.contains("March 15"), "got \(r)")
        #expect(r.contains("2024"), "got \(r)")
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
