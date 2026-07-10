import Testing
@testable import Chirp

@Suite("TextPostProcessor")
struct TextPostProcessorTests {

    @Test("Passes through clean text unchanged")
    func passthrough() {
        #expect(TextPostProcessor.process("Hello world.") == "Hello world.")
    }

    @Test("Removes filler words")
    func fillerRemoval() {
        #expect(TextPostProcessor.process("So um the quick brown fox") == "So the quick brown fox")
        #expect(TextPostProcessor.process("uh hello there") == "hello there")
        #expect(TextPostProcessor.process("I was uh thinking about it") == "I was thinking about it")
        #expect(TextPostProcessor.process("hmm let me think") == "let me think")
    }

    @Test("Removes fillers case-insensitively")
    func fillerCaseInsensitive() {
        #expect(TextPostProcessor.process("Um hello") == "hello")
        #expect(TextPostProcessor.process("UM hello") == "hello")
    }

    @Test("Deduplicates repeated words")
    func repetitionDedup() {
        #expect(TextPostProcessor.process("the the quick fox") == "the quick fox")
        #expect(TextPostProcessor.process("I I I want this") == "I want this")
        #expect(TextPostProcessor.process("go go go") == "go")
    }

    @Test("Removes space before punctuation")
    func spaceBeforePunct() {
        #expect(TextPostProcessor.process("Hello .") == "Hello.")
        #expect(TextPostProcessor.process("What ?") == "What?")
        #expect(TextPostProcessor.process("Wait , no") == "Wait, no")
    }

    @Test("Collapses multiple spaces")
    func multipleSpaces() {
        #expect(TextPostProcessor.process("Hello   world") == "Hello world")
    }

    @Test("Capitalizes standalone i")
    func capitalizeI() {
        #expect(TextPostProcessor.process("i think so") == "I think so")
        #expect(TextPostProcessor.process("when i go i'll be fine") == "when I go I'll be fine")
    }

    @Test("Does not capitalize i inside words")
    func noCapitalizeInWords() {
        #expect(TextPostProcessor.process("inside this") == "inside this")
        #expect(TextPostProcessor.process("fix it") == "fix it")
    }

    @Test("Handles empty string")
    func emptyString() {
        #expect(TextPostProcessor.process("") == "")
    }

    @Test("Handles filler-only input")
    func fillerOnly() {
        #expect(TextPostProcessor.process("um uh er") == "")
    }

    @Test("Combined: fillers + repetition + whitespace + i")
    func combined() {
        let input = "um i i was  uh thinking about the the  problem ."
        let expected = "I was thinking about the problem."
        #expect(TextPostProcessor.process(input) == expected)
    }

    @Test("Preserves legitimate words containing filler substrings")
    func preservesLegitimateWords() {
        #expect(TextPostProcessor.process("umbrella") == "umbrella")
        #expect(TextPostProcessor.process("perhaps") == "perhaps")
        #expect(TextPostProcessor.process("gopher") == "gopher")
    }

    @Test("Trims leading and trailing whitespace")
    func trimming() {
        #expect(TextPostProcessor.process("  hello  ") == "hello")
    }

    @Test("Drops silence-hallucination-only utterances")
    func silenceHallucinations() {
        #expect(TextPostProcessor.process("you") == "")
        #expect(TextPostProcessor.process("thank you.") == "")
        #expect(TextPostProcessor.process("Thank you for watching.") == "")
        #expect(TextPostProcessor.process("hmm") == "")
        // Legitimate single-word dictation must pass through
        #expect(TextPostProcessor.process("Yeah") == "Yeah")
        #expect(TextPostProcessor.process("Okay") == "Okay")
        #expect(TextPostProcessor.process("goodbye") == "goodbye")
        #expect(TextPostProcessor.process("yes") == "yes")
        // Multi-word speech must pass through
        #expect(TextPostProcessor.process("yeah I agree") == "yeah I agree")
        #expect(TextPostProcessor.process("thank you so much") == "thank you so much")
        #expect(TextPostProcessor.process("okay let's go") == "okay let's go")
    }

    @Test("Collapses repeated punctuation")
    func multiPunct() {
        #expect(TextPostProcessor.process("Hello??") == "Hello?")
        #expect(TextPostProcessor.process("Wait..") == "Wait.")
    }

    @Test("Fixes high-confidence dictation confusions")
    func phraseFixes() {
        #expect(TextPostProcessor.process("Create a new node.") == "Create a new note.")
        #expect(TextPostProcessor.process("I need new nodes") == "I need new notes")
        // Unrelated "node" must stay
        #expect(TextPostProcessor.process("graph node") == "graph node")
    }

    @Test("Spoken punctuation commands")
    func spokenPunctuation() {
        #expect(TextPostProcessor.process("Hello world period") == "Hello world.")
        #expect(TextPostProcessor.process("Wait comma no") == "Wait, no")
        #expect(TextPostProcessor.process("are you there question mark") == "are you there?")
        #expect(TextPostProcessor.process("wow exclamation mark") == "wow!")
        // Content-word collocations keep the word "period"
        #expect(TextPostProcessor.process("the period is over") == "the period is over")
        #expect(TextPostProcessor.process("grace period ends soon").contains("period"))
    }

    @Test("Mid-segment spoken terminal punctuation")
    func midSegmentTerminalPunct() {
        #expect(TextPostProcessor.process("hello period next sentence") == "hello. Next sentence")
        #expect(TextPostProcessor.process("stop full stop go on") == "stop. Go on")
        #expect(TextPostProcessor.process("are you there question mark yes") == "are you there? Yes")
        #expect(TextPostProcessor.process("wow exclamation mark great") == "wow! Great")
        // Multi-clause one breath
        #expect(
            TextPostProcessor.process("first clause period second clause period")
                == "first clause. Second clause."
        )
    }

    @Test("Spoken new line and paragraph commands")
    func spokenNewlines() {
        #expect(TextPostProcessor.process("Hello new line world") == "Hello\nWorld")
        #expect(TextPostProcessor.process("One new paragraph Two") == "One\n\nTwo")
        #expect(TextPostProcessor.process("line newline break") == "line\nBreak")
    }

    @Test("Capitalizes after terminal punct and newlines")
    func capitalizeAfterPunct() {
        #expect(TextPostProcessor.process("hello. world") == "hello. World")
        #expect(TextPostProcessor.process("wait? next") == "wait? Next")
        #expect(TextPostProcessor.process("wow! yes") == "wow! Yes")
        #expect(TextPostProcessor.capitalizeAfterTerminalPunct("a… b") == "a… B")
        // Decimals without space stay put
        #expect(TextPostProcessor.process("pi is 3.14 exactly").contains("3.14"))
        // Content word "period" mid-sentence unchanged
        #expect(TextPostProcessor.process("the period is over") == "the period is over")
        // Trailing spoken period only
        let trailing = TextPostProcessor.process("Hello world period")
        #expect(trailing == "Hello world." || trailing == "hello world.")
    }

    @Test("Spoken domain and at-sign fragments")
    func spokenDomain() {
        #expect(TextPostProcessor.process("visit example dot com") == "visit example.com")
        #expect(TextPostProcessor.process("mail me at sign you") == "mail me@you")
        #expect(TextPostProcessor.process("site dot io") == "site.io")
    }

    @Test("Expanded spoken punctuation")
    func expandedPunctuation() {
        #expect(TextPostProcessor.process("items colon one") == "items: one")
        #expect(TextPostProcessor.process("wait semicolon go") == "wait; go")
        #expect(TextPostProcessor.process("open quote hi close quote") == "\u{201C}hi\u{201D}")
        #expect(TextPostProcessor.process("open paren x close paren") == "(x)")
        #expect(TextPostProcessor.process("tag hashtag chirp") == "tag#chirp")
        #expect(TextPostProcessor.process("a and b ampersand c").contains("&"))
        #expect(TextPostProcessor.process("done ellipsis") == "done…")
        #expect(TextPostProcessor.process("word em dash word").contains("—"))
        let fullStop = TextPostProcessor.process("done full stop")
        #expect(fullStop == "done." || fullStop == "Done.")
    }

    @Test("Light ITN formats spoken times")
    func lightITN() {
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
        #expect(TextPostProcessor.process("Call me at 9 am") == "Call me at 9 a.m.")
        #expect(TextPostProcessor.process("see you at twelve p.m.") == "see you at 12 p.m.")
        // Non-time "one" must stay
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
    }

    @Test("Light ITN formats percent and dollars")
    func lightITNPercentCurrency() {
        #expect(TextPostProcessor.process("about 50 percent done") == "about 50% done")
        #expect(TextPostProcessor.process("fifty percent complete") == "50% complete")
        #expect(TextPostProcessor.process("costs 20 dollars") == "costs $20")
        #expect(TextPostProcessor.process("pay twenty dollars now") == "pay $20 now")
        #expect(TextPostProcessor.process("one dollar please").contains("$1"))
        // Bare numbers / words without unit stay put
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
        #expect(TextPostProcessor.process("percent of cases") == "percent of cases")
    }


    @Test("Does not drop bare function words as whole utterance")
    func keepsBareFunctionWords() {
        // Early VAD endpoints can decode a single onset word; dropping it loses speech.
        #expect(TextPostProcessor.process("the") == "the")
        #expect(TextPostProcessor.process("a") == "a")
        #expect(TextPostProcessor.process("to") == "to")
    }
}
