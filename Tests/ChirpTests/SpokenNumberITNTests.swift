// SpokenNumberITNTests.swift — Multi-token spoken cardinal ITN.

import Testing
@testable import Chirp

@Suite("SpokenNumberITN")
struct SpokenNumberITNTests {

    @Test("does not convert bare small units without quantity noun")
    func bareUnitsStay() {
        #expect(SpokenNumberITN.apply("one more thing") == "one more thing")
        #expect(SpokenNumberITN.apply("two birds") == "two birds")
        // Non-quantity follow-on stays words
        #expect(SpokenNumberITN.apply("ten things") == "ten things")
    }

    @Test("converts bare units before quantity nouns")
    func quantityNounForceConvert() {
        #expect(SpokenNumberITN.apply("ten items") == "10 items")
        #expect(SpokenNumberITN.apply("five emails") == "5 emails")
        #expect(SpokenNumberITN.apply("three people") == "3 people")
        #expect(SpokenNumberITN.apply("one person") == "1 person")
        #expect(SpokenNumberITN.apply("two files") == "2 files")
        #expect(SpokenNumberITN.apply("four messages") == "4 messages")
        #expect(SpokenNumberITN.apply("six pages") == "6 pages")
        #expect(SpokenNumberITN.apply("seven tickets") == "7 tickets")
        #expect(SpokenNumberITN.apply("eight seats") == "8 seats")
        #expect(SpokenNumberITN.apply("nine users") == "9 users")
        #expect(SpokenNumberITN.apply("twelve copies") == "12 copies")
        #expect(SpokenNumberITN.apply("five apples") == "5 apples")
        #expect(SpokenNumberITN.apply("two oranges") == "2 oranges")
        // Dictation staples
        #expect(SpokenNumberITN.apply("three notes") == "3 notes")
        #expect(SpokenNumberITN.apply("five tasks") == "5 tasks")
        #expect(SpokenNumberITN.apply("two meetings") == "2 meetings")
        #expect(SpokenNumberITN.apply("four bugs") == "4 bugs")
        #expect(SpokenNumberITN.apply("ten lines") == "10 lines")
        #expect(SpokenNumberITN.apply("six words") == "6 words")
        #expect(SpokenNumberITN.apply("three commits") == "3 commits")
        #expect(SpokenNumberITN.apply("two documents") == "2 documents")
        #expect(SpokenNumberITN.apply("eight hours") == "8 hours")
        #expect(SpokenNumberITN.apply("fifteen minutes") == "15 minutes")
        #expect(SpokenNumberITN.apply("five comments") == "5 comments")
        #expect(SpokenNumberITN.apply("two issues") == "2 issues")
        #expect(SpokenNumberITN.apply("three sentences") == "3 sentences")
        // Compounds already convert; quantity still fine
        #expect(SpokenNumberITN.apply("twenty five apples") == "25 apples")
        // "of them" / non-quantity do not force
        #expect(SpokenNumberITN.apply("ten of them") == "ten of them")
        #expect(SpokenNumberITN.apply("one more thing") == "one more thing")
    }

    @Test("frequency: N times a day/week converts; bare three times stays")
    func frequencyTimesAPeriod() {
        #expect(SpokenNumberITN.apply("three times a day") == "3 times a day")
        #expect(SpokenNumberITN.apply("ten times a week") == "10 times a week")
        #expect(SpokenNumberITN.apply("two times a month") == "2 times a month")
        #expect(SpokenNumberITN.apply("five times an hour") == "5 times an hour")
        #expect(SpokenNumberITN.apply("four times a year") == "4 times a year")
        #expect(SpokenNumberITN.apply("twenty five times a day") == "25 times a day")
        // per: "three times per day"
        #expect(SpokenNumberITN.apply("three times per day") == "3 times per day")
        #expect(SpokenNumberITN.apply("ten times per week") == "10 times per week")
        // once / twice a day (not bare "once" / "twice")
        #expect(SpokenNumberITN.apply("once a day") == "1 time a day")
        #expect(SpokenNumberITN.apply("twice a week") == "2 times a week")
        #expect(SpokenNumberITN.apply("once per month") == "1 time per month")
        #expect(SpokenNumberITN.apply("twice per hour") == "2 times per hour")
        // Bare "three times" / multiply sense — do not force
        #expect(SpokenNumberITN.apply("three times") == "three times")
        #expect(SpokenNumberITN.apply("two times faster") == "two times faster")
        #expect(SpokenNumberITN.apply("times a day") == "times a day")
        #expect(SpokenNumberITN.apply("once more") == "once more")
        #expect(SpokenNumberITN.apply("twice as fast") == "twice as fast")
    }

    @Test("converts teens and tens compounds")
    func teensAndCompounds() {
        #expect(SpokenNumberITN.apply("I saw fifteen birds") == "I saw 15 birds")
        #expect(SpokenNumberITN.apply("twenty five apples") == "25 apples")
        #expect(SpokenNumberITN.apply("ninety nine") == "99")
        #expect(SpokenNumberITN.apply("twenty") == "20")
    }

    @Test("converts hundreds and thousands")
    func magnitudes() {
        #expect(SpokenNumberITN.apply("one hundred") == "100")
        #expect(SpokenNumberITN.apply("two hundred fifty") == "250")
        #expect(SpokenNumberITN.apply("one hundred and five") == "105")
        #expect(SpokenNumberITN.apply("three thousand") == "3000")
        #expect(SpokenNumberITN.apply("one thousand two hundred") == "1200")
    }

    @Test("converts decimals with point")
    func decimals() {
        #expect(SpokenNumberITN.apply("three point five") == "3.5")
        #expect(SpokenNumberITN.apply("ten point two five") == "10.25")
    }

    @Test("parsePhrase unit tests")
    func parsePhrase() {
        #expect(SpokenNumberITN.parsePhrase(["twenty", "one"]) == 21)
        #expect(SpokenNumberITN.parsePhrase(["one", "hundred"]) == 100)
        #expect(SpokenNumberITN.parsePhrase(["one"]) == 1) // parse ok; apply() refuses convert
        #expect(SpokenNumberITN.parsePhrase(["point", "five"]) == nil)
    }

    @Test("ordinals convert with discourse guards")
    func ordinals() {
        #expect(SpokenNumberITN.formatOrdinal(1) == "1st")
        #expect(SpokenNumberITN.formatOrdinal(2) == "2nd")
        #expect(SpokenNumberITN.formatOrdinal(3) == "3rd")
        #expect(SpokenNumberITN.formatOrdinal(11) == "11th")
        #expect(SpokenNumberITN.formatOrdinal(21) == "21st")
        #expect(SpokenNumberITN.apply("came in first") == "came in 1st")
        #expect(SpokenNumberITN.apply("twenty first birthday") == "21st birthday")
        #expect(SpokenNumberITN.apply("the fifteenth floor") == "the 15th floor")
        // Discourse idioms stay words
        #expect(SpokenNumberITN.apply("first of all") == "first of all")
        #expect(SpokenNumberITN.apply("first class cabin") == "first class cabin")
        #expect(SpokenNumberITN.apply("first time here") == "first time here")
    }

    @Test("digit runs concatenate single-digit units (phone-style)")
    func digitRuns() {
        // ≥3 single digits → concatenate, not sum; 7-digit formats with dash
        let phone = SpokenNumberITN.apply("call five five five one two one two")
        #expect(phone.contains("555-1212"), "expected 555-1212 in \"\(phone)\"")
        // Leading zero ("oh") preserved; 4-digit runs stay unformatted
        #expect(SpokenNumberITN.apply("oh five five five") == "0555")
        // Compounds still sum / parse as numbers
        #expect(SpokenNumberITN.apply("twenty five") == "25")
        #expect(SpokenNumberITN.apply("one hundred") == "100")
        // Bare unit and short runs stay conversational
        #expect(SpokenNumberITN.apply("one more thing") == "one more thing")
        #expect(SpokenNumberITN.apply("one two") == "one two")
        #expect(SpokenNumberITN.apply("five five") == "five five")
    }

    @Test("digit runs of ≥1 force-convert after suite/room/floor/ext cues")
    func digitRunsAfterAddressCues() {
        // Single digit after cue
        #expect(SpokenNumberITN.apply("suite five") == "suite 5")
        #expect(SpokenNumberITN.apply("floor five") == "floor 5")
        #expect(SpokenNumberITN.apply("room one") == "room 1")
        // Multi-digit runs after cue
        #expect(SpokenNumberITN.apply("suite five five") == "suite 55")
        #expect(SpokenNumberITN.apply("floor five five") == "floor 55")
        #expect(SpokenNumberITN.apply("room one zero one") == "room 101")
        #expect(SpokenNumberITN.apply("extension five five") == "extension 55")
        #expect(SpokenNumberITN.apply("ext five five") == "ext 55")
        #expect(SpokenNumberITN.apply("apt two five") == "apt 25")
        #expect(SpokenNumberITN.apply("unit two zero") == "unit 20")
        #expect(SpokenNumberITN.apply("apartment one two") == "apartment 12")
        // Uncued short runs still stay words
        #expect(SpokenNumberITN.apply("five five") == "five five")
        #expect(SpokenNumberITN.apply("one two") == "one two")
    }

    @Test("force-converts bare units and decimals after version cue")
    func forceConvertAfterVersionCue() {
        #expect(SpokenNumberITN.apply("version two") == "version 2")
        #expect(SpokenNumberITN.apply("version three") == "version 3")
        #expect(SpokenNumberITN.apply("version one point two") == "version 1.2")
        #expect(SpokenNumberITN.apply("version one point five") == "version 1.5")
        // Already digits stay digits after cue
        #expect(SpokenNumberITN.apply("version 3") == "version 3")
        // Prose without a number after "version" is untouched
        #expect(SpokenNumberITN.apply("the version is fine") == "the version is fine")
        #expect(SpokenNumberITN.apply("version of the product") == "version of the product")
    }

    @Test("formats phone-length digit runs with dashes")
    func phoneDashFormatting() {
        // 7 digits: XXX-XXXX
        #expect(SpokenNumberITN.apply("five five five one two one two") == "555-1212")
        // 10 digits: XXX-XXX-XXXX
        #expect(
            SpokenNumberITN.apply("five five five one two three four five six seven")
                == "555-123-4567"
        )
        // 11 starting with 1: 1-XXX-XXX-XXXX
        #expect(
            SpokenNumberITN.apply("one eight zero zero five five five one two one two")
                == "1-800-555-1212"
        )
        // Non-phone lengths stay plain digits
        #expect(SpokenNumberITN.apply("five five five") == "555")
        #expect(SpokenNumberITN.apply("oh five five five") == "0555")
        // Years / short codes stay plain
        #expect(SpokenNumberITN.apply("two zero two four") == "2024")
    }

    /// Live ASR often emits a plain digit blob ("Call 5551212.") without dashes.
    @Test("formats bare phone-length digit tokens from ASR")
    func barePhoneDigitTokens() {
        #expect(SpokenNumberITN.apply("call 5551212") == "call 555-1212")
        #expect(SpokenNumberITN.apply("Call 5551212.") == "Call 555-1212.")
        #expect(SpokenNumberITN.apply("5551234567") == "555-123-4567")
        #expect(SpokenNumberITN.apply("18005551212") == "1-800-555-1212")
        // Already dashed stays
        #expect(SpokenNumberITN.apply("call 555-1212") == "call 555-1212")
        // Non-phone lengths untouched
        #expect(SpokenNumberITN.apply("room 101") == "room 101")
        #expect(SpokenNumberITN.apply("2024") == "2024")
        #expect(SpokenNumberITN.apply("55512121") == "55512121") // 8 digits
    }

    @Test("dozen multiplies spoken counts by twelve")
    func dozenMultiplier() {
        #expect(SpokenNumberITN.apply("two dozen") == "24")
        #expect(SpokenNumberITN.apply("five dozen") == "60")
        #expect(SpokenNumberITN.apply("five dozen eggs") == "60 eggs")
        #expect(SpokenNumberITN.apply("a dozen") == "12")
        #expect(SpokenNumberITN.apply("one dozen") == "12")
        #expect(SpokenNumberITN.apply("half a dozen") == "6")
        #expect(SpokenNumberITN.apply("half dozen") == "6")
        #expect(SpokenNumberITN.apply("twenty five dozen") == "300")
        #expect(SpokenNumberITN.apply("I bought two dozen") == "I bought 24")
        #expect(SpokenNumberITN.apply("minus two dozen") == "-24")
        // Guards
        #expect(SpokenNumberITN.apply("dozen") == "dozen")
        #expect(SpokenNumberITN.apply("dozens of people") == "dozens of people")
        #expect(SpokenNumberITN.apply("by the dozen") == "by the dozen")
        #expect(SpokenNumberITN.apply("the dozen") == "the dozen")
        #expect(SpokenNumberITN.apply("one more thing") == "one more thing")
    }

    @Test("N and a half dozen multiplies to N*12+6")
    func andAHalfDozen() {
        #expect(SpokenNumberITN.apply("two and a half dozen") == "30")
        #expect(SpokenNumberITN.apply("one and a half dozen") == "18")
        #expect(SpokenNumberITN.apply("three and a half dozen") == "42")
        #expect(SpokenNumberITN.apply("two and a half dozen eggs") == "30 eggs")
        #expect(SpokenNumberITN.apply("I need two and a half dozen") == "I need 30")
        #expect(SpokenNumberITN.apply("two and half dozen") == "30")
        #expect(SpokenNumberITN.apply("half a dozen") == "6")
    }

    @Test("general N and a half beyond hardcoded 1–5")
    func generalAndAHalf() {
        #expect(SpokenNumberITN.apply("six and a half") == "6½")
        #expect(SpokenNumberITN.apply("seven and a half") == "7½")
        #expect(SpokenNumberITN.apply("ten and a half cups") == "10½ cups")
        #expect(SpokenNumberITN.apply("twenty and a half") == "20½")
        #expect(SpokenNumberITN.apply("twenty two and a half") == "22½")
        #expect(SpokenNumberITN.apply("6 and a half") == "6½")
        #expect(SpokenNumberITN.apply("two and half") == "2½")
        // Keep dozen compounds
        #expect(SpokenNumberITN.apply("two and a half dozen") == "30")
        #expect(SpokenNumberITN.apply("one and a half") == "1½")
        #expect(SpokenNumberITN.apply("five and a half") == "5½")
        #expect(SpokenNumberITN.apply("three point five") == "3.5")
    }

    @Test("a couple of / a pair of force two")
    func coupleAndPairOf() {
        #expect(SpokenNumberITN.apply("a couple of minutes") == "2 minutes")
        #expect(SpokenNumberITN.apply("a couple of eggs") == "2 eggs")
        #expect(SpokenNumberITN.apply("need a couple of files") == "need 2 files")
        #expect(SpokenNumberITN.apply("a pair of shoes") == "2 shoes")
        #expect(SpokenNumberITN.apply("bring a pair of socks") == "bring 2 socks")
        #expect(SpokenNumberITN.apply("couple of days") == "2 days")
        #expect(SpokenNumberITN.apply("pair of socks") == "2 socks")
        // Guards
        #expect(SpokenNumberITN.apply("a couple") == "a couple")
        #expect(SpokenNumberITN.apply("power couple") == "power couple")
        #expect(SpokenNumberITN.apply("couple more") == "couple more")
        #expect(SpokenNumberITN.apply("a pair") == "a pair")
        #expect(SpokenNumberITN.apply("pair programming") == "pair programming")
    }

    @Test("force-number cues include chapter gate aisle page")
    func expandedForceNumberCues() {
        #expect(SpokenNumberITN.apply("chapter five") == "chapter 5")
        #expect(SpokenNumberITN.apply("page twelve") == "page 12")
        #expect(SpokenNumberITN.apply("gate twelve") == "gate 12")
        #expect(SpokenNumberITN.apply("aisle three") == "aisle 3")
        #expect(SpokenNumberITN.apply("channel four") == "channel 4")
        #expect(SpokenNumberITN.apply("episode two") == "episode 2")
        #expect(SpokenNumberITN.apply("season three") == "season 3")
        #expect(SpokenNumberITN.apply("pin four five six seven") == "pin 4567")
        #expect(SpokenNumberITN.apply("code nine nine") == "code 99")
        // Uncued short runs still words
        #expect(SpokenNumberITN.apply("five five") == "five five")
    }

    @Test("double/triple digit repeats expand in phone-style runs")
    func doubleTripleDigitRuns() {
        // "double five" → two fives inside a run
        #expect(SpokenNumberITN.apply("double five five one two one two") == "555-1212")
        #expect(SpokenNumberITN.apply("five double five one two one two") == "555-1212")
        #expect(SpokenNumberITN.apply("triple five one two one two") == "555-1212")
        // triple oh → three zeros; + five continues the digit run
        #expect(SpokenNumberITN.apply("triple oh five") == "0005")
        #expect(SpokenNumberITN.apply("double oh five five") == "0055")
        // Bare letter-o zero (ASR often drops "h" from oh)
        #expect(SpokenNumberITN.apply("o five five five") == "0555")
        // 8 digits (o + 7) stay plain — phone dash only for 7/10/11
        #expect(SpokenNumberITN.apply("o five five five one two one two") == "05551212")
        #expect(SpokenNumberITN.apply("call double five five one two one two") == "call 555-1212")
        // Free dictation: double/triple before non-digits stay words
        #expect(SpokenNumberITN.apply("double check that") == "double check that")
        #expect(SpokenNumberITN.apply("triple jump") == "triple jump")
        #expect(SpokenNumberITN.apply("double the amount") == "double the amount")
        #expect(SpokenNumberITN.apply("triple a") == "triple a")
    }

    @Test("negative numbers via minus/negative prefix")
    func negativeNumbers() {
        #expect(SpokenNumberITN.apply("minus twenty") == "-20")
        #expect(SpokenNumberITN.apply("negative twenty") == "-20")
        #expect(SpokenNumberITN.apply("minus five") == "-5")
        #expect(SpokenNumberITN.apply("negative five") == "-5")
        #expect(SpokenNumberITN.apply("minus one hundred") == "-100")
        #expect(SpokenNumberITN.apply("minus five five five") == "-555")
        #expect(SpokenNumberITN.apply("temperature is minus twenty") == "temperature is -20")
        // Bare "minus" / non-numeric follow-ons stay words (not signed)
        #expect(SpokenNumberITN.apply("minus") == "minus")
        #expect(SpokenNumberITN.apply("minus sign") == "minus sign")
        // "minus" not followed by a number phrase → leave "minus"; ordinal may still ITN
        #expect(SpokenNumberITN.apply("minus the first one") == "minus the 1st one")
        #expect(SpokenNumberITN.apply("negative") == "negative")
    }
}

@Suite("TextPostProcessor number ITN")
struct TextPostProcessorNumberITNTests {

    @Test("integrates bare ASR phone digit blobs with dashes")
    func barePhoneThroughPipeline() {
        let r = TextPostProcessor.process("Call 5551212.")
        #expect(r.contains("555-1212"), "got \(r)")
        #expect(!r.contains("5551212"), "got \(r)")
    }

    @Test("integrates cardinals with dollars and percent")
    func integrated() {
        #expect(TextPostProcessor.process("costs one hundred dollars") == "costs $100")
        #expect(TextPostProcessor.process("about fifty percent done") == "about 50% done")
        #expect(TextPostProcessor.process("one hundred percent ready") == "100% ready")
        // Bare one stays; quantity noun forces digits
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
        #expect(TextPostProcessor.process("five emails") == "5 emails")
        #expect(TextPostProcessor.process("ten items") == "10 items")
    }

    @Test("meeting times still work after cardinal ITN")
    func timesStillWork() {
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
    }
}
