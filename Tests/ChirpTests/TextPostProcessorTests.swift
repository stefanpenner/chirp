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
        // Word "period" mid-sentence (not trailing) stays
        #expect(TextPostProcessor.process("the period is over") == "the period is over")
    }

    @Test("Light ITN formats spoken times")
    func lightITN() {
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
        #expect(TextPostProcessor.process("Call me at 9 am") == "Call me at 9 a.m.")
        #expect(TextPostProcessor.process("see you at twelve p.m.") == "see you at 12 p.m.")
        // Non-time "one" must stay
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
    }


    @Test("Does not drop bare function words as whole utterance")
    func keepsBareFunctionWords() {
        // Early VAD endpoints can decode a single onset word; dropping it loses speech.
        #expect(TextPostProcessor.process("the") == "the")
        #expect(TextPostProcessor.process("a") == "a")
        #expect(TextPostProcessor.process("to") == "to")
    }
}
