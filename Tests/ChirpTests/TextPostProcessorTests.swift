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
        #expect(TextPostProcessor.process("Ready .") == "Ready.")
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

    @Test("Packs spoken single-letter acronyms")
    func packSpokenAcronyms() {
        #expect(TextPostProcessor.process("a p i") == "API")
        #expect(TextPostProcessor.process("open the u r l now") == "open the URL now")
        #expect(TextPostProcessor.process("I am fine") == "I am fine")
        #expect(TextPostProcessor.process("call the a p i please") == "call the API please")
        #expect(TextPostProcessor.process("a p i.") == "API.")
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
        #expect(TextPostProcessor.process("thanks for listening.") == "")
        #expect(TextPostProcessor.process("Thanks for listening") == "")
        #expect(TextPostProcessor.process("bye.") == "")
        #expect(TextPostProcessor.process("bye") == "")
        #expect(TextPostProcessor.process("okay.") == "")
        #expect(TextPostProcessor.process("ok.") == "")
        #expect(TextPostProcessor.process("hello.") == "")
        #expect(TextPostProcessor.process("hello?") == "")
        #expect(TextPostProcessor.process("hi.") == "")
        #expect(TextPostProcessor.process("hi?") == "")
        #expect(TextPostProcessor.process("you know.") == "")
        #expect(TextPostProcessor.process("i mean.") == "")
        // Expanded Whisper-class silence dumps
        #expect(TextPostProcessor.process("please like and subscribe.") == "")
        #expect(TextPostProcessor.process("please like and subscribe") == "")
        #expect(TextPostProcessor.process("thanks for watching!") == "")
        #expect(TextPostProcessor.process("the end.") == "")
        #expect(TextPostProcessor.process("the end") == "")
        #expect(TextPostProcessor.process("subtitles by the amara.org community") == "")
        #expect(TextPostProcessor.process("music") == "")
        #expect(TextPostProcessor.process("[music]") == "")
        #expect(TextPostProcessor.process("applause") == "")
        #expect(TextPostProcessor.process("laughter") == "")
        // Common production silence dumps (Whisper-class)
        #expect(TextPostProcessor.process("thanks for watching, and i'll see you next time.") == "")
        #expect(TextPostProcessor.process("thank you so much for joining us.") == "")
        #expect(TextPostProcessor.process("see you next time.") == "")
        #expect(TextPostProcessor.process("see you next time") == "")
        // Punctuated short fillers (VAD false endpoint dumps)
        #expect(TextPostProcessor.process("yeah.") == "")
        #expect(TextPostProcessor.process("yes.") == "")
        #expect(TextPostProcessor.process("yeah?") == "")
        #expect(TextPostProcessor.process("yes?") == "")
        #expect(TextPostProcessor.process("you.") == "")
        #expect(TextPostProcessor.process("you?") == "")
        // Legitimate single-word dictation must pass through (no trailing punct)
        #expect(TextPostProcessor.process("Yeah") == "Yeah")
        #expect(TextPostProcessor.process("Okay") == "Okay")
        #expect(TextPostProcessor.process("ok") == "ok")
        #expect(TextPostProcessor.process("hello") == "hello")
        #expect(TextPostProcessor.process("hi") == "hi")
        #expect(TextPostProcessor.process("goodbye") == "goodbye")
        #expect(TextPostProcessor.process("yes") == "yes")
        #expect(TextPostProcessor.process("yeah") == "yeah")
        // Multi-word speech must pass through
        #expect(TextPostProcessor.process("yeah I agree") == "yeah I agree")
        #expect(TextPostProcessor.process("thank you so much") == "thank you so much")
        #expect(TextPostProcessor.process("okay let's go") == "okay let's go")
        #expect(TextPostProcessor.process("hello there") == "hello there")
        #expect(TextPostProcessor.process("you know what") == "you know what")
        #expect(TextPostProcessor.process("the end of the road") == "the end of the road")
    }

    @Test("Collapses repeated punctuation")
    func multiPunct() {
        #expect(TextPostProcessor.process("Ready??") == "Ready?")
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
        // Multi-clause one breath (avoid ordinal words first/second)
        #expect(
            TextPostProcessor.process("alpha clause period beta clause period")
                == "alpha clause. Beta clause."
        )
    }

    @Test("Spoken new line and paragraph commands")
    func spokenNewlines() {
        #expect(TextPostProcessor.process("Hello new line world") == "Hello\nWorld")
        #expect(TextPostProcessor.process("One new paragraph Two") == "One\n\nTwo")
        #expect(TextPostProcessor.process("line newline break") == "line\nBreak")
        #expect(TextPostProcessor.process("Hello line break world") == "Hello\nWorld")
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
        #expect(TextPostProcessor.process("mail me at sign you") == "mail me @you")
        #expect(TextPostProcessor.process("site dot io") == "site.io")
        #expect(TextPostProcessor.process("visit site dot co") == "visit site.co")
        // "dot company" must not become ".company"
        #expect(TextPostProcessor.process("dot company").contains("company"))
    }

    @Test("Spoken URL ITN www and protocol")
    func spokenURL() {
        #expect(TextPostProcessor.process("www dot example dot com") == "www.example.com")
        #expect(TextPostProcessor.process("visit www dot example dot com") == "visit www.example.com")
        #expect(TextPostProcessor.process("w w w dot example dot org") == "www.example.org")
        #expect(TextPostProcessor.process("double you double you double you dot example dot net")
                == "www.example.net")
        #expect(TextPostProcessor.process("https colon slash slash example dot com")
                == "https://example.com")
        #expect(TextPostProcessor.process("http colon slash slash example dot io")
                == "http://example.io")
        #expect(TextPostProcessor.process("https colon forward slash forward slash example dot com")
                == "https://example.com")
        // Bare www without domain stays www
        #expect(TextPostProcessor.process("say www please").contains("www"))
    }

    @Test("Spoken email-ish rewrite")
    func spokenEmail() {
        #expect(TextPostProcessor.process("john at example dot com") == "john@example.com")
        #expect(TextPostProcessor.process("Jane at Acme dot org") == "Jane@Acme.org")
        #expect(TextPostProcessor.process("dev at foo dot io") == "dev@foo.io")
        // Multi-label domains
        #expect(TextPostProcessor.process("john at mail dot google dot com") == "john@mail.google.com")
        #expect(TextPostProcessor.process("dev at example dot co dot uk") == "dev@example.co.uk")
        // Local-part spoken symbols before "at"
        #expect(TextPostProcessor.process("john underscore smith at example dot com")
                == "john_smith@example.com")
        #expect(TextPostProcessor.process("john dot smith at example dot com")
                == "john.smith@example.com")
        #expect(TextPostProcessor.process("john plus test at example dot com")
                == "john+test@example.com")
        // "at" without trailing "dot …" stays conversational
        #expect(TextPostProcessor.process("meet at noon") == "meet at noon")
        #expect(TextPostProcessor.process("look at this") == "look at this")
    }

    /// ASR dumps: dat≈dot, period+TLD, "at the", "under score".
    @Test("Spoken email ASR near-misses")
    func spokenEmailNearMisses() {
        #expect(TextPostProcessor.process("john at example dat com") == "john@example.com")
        #expect(TextPostProcessor.process("visit example dat com") == "visit example.com")
        #expect(TextPostProcessor.process("john at example period com") == "john@example.com")
        #expect(TextPostProcessor.process("john at the example dot com") == "john@example.com")
        #expect(TextPostProcessor.process("john under score smith at example dot com")
                == "john_smith@example.com")
        // Live ASR often glues TLD first: "john at example.com" (ITN audio dump)
        #expect(TextPostProcessor.process("john at example.com") == "john@example.com")
        #expect(TextPostProcessor.process("Jane_smith at example.org") == "Jane_smith@example.org")
        // ASR drops "dot": "john at example com"
        #expect(TextPostProcessor.process("john at example com") == "john@example.com")
        #expect(TextPostProcessor.process("jane at the gmail com") == "jane@gmail.com")
        #expect(TextPostProcessor.process("dev at foo io") == "dev@foo.io")
        #expect(TextPostProcessor.process("john underscore smith at example com")
                == "john_smith@example.com")
        #expect(TextPostProcessor.process("john at mail google com") == "john@mail.google.com")
        // Conversational "at" / content "period" must not steal
        #expect(TextPostProcessor.process("meet at noon") == "meet at noon")
        #expect(TextPostProcessor.process("look at this") == "look at this")
        #expect(TextPostProcessor.process("look at me") == "look at me")
        #expect(TextPostProcessor.process("the period is over") == "the period is over")
    }

    @Test("Bare domain TLD glue without spoken dot")
    func bareDomainMissingDot() {
        #expect(TextPostProcessor.process("visit example com") == "visit example.com")
        // Avoid relative-date word "today" (expandRelativeDates)
        #expect(TextPostProcessor.process("see acme org please") == "see acme.org please")
        #expect(TextPostProcessor.process("www example com") == "www.example.com")
        // Short ambiguous TLDs stay prose
        #expect(TextPostProcessor.process("look at me") == "look at me")
        #expect(TextPostProcessor.process("new app") == "new app")
        #expect(TextPostProcessor.process("dot company").contains("company"))
        // Spoken connector path must still work (not "dot.org")
        #expect(TextPostProcessor.process("site dot edu") == "site.edu")
        #expect(TextPostProcessor.process("visit example dat com") == "visit example.com")
    }

    @Test("Expanded spoken punctuation")
    func expandedPunctuation() {
        #expect(TextPostProcessor.process("items colon one") == "items: one")
        #expect(TextPostProcessor.process("wait semicolon go") == "wait; go")
        #expect(TextPostProcessor.process("open quote hi close quote") == "\u{201C}hi\u{201D}")
        #expect(TextPostProcessor.process("open paren x close paren") == "(x)")
        #expect(TextPostProcessor.process("a and b ampersand c").contains("&"))
        #expect(TextPostProcessor.process("done ellipsis") == "done…")
        #expect(TextPostProcessor.process("word em dash word").contains("—"))
        let fullStop = TextPostProcessor.process("done full stop")
        #expect(fullStop == "done." || fullStop == "Done.")
        // Segment-start comma/colon (lone VAD chunk)
        #expect(TextPostProcessor.process("comma wait") == ", wait" || TextPostProcessor.process("comma wait") == ", Wait")
        #expect(TextPostProcessor.process("colon list") == ": list" || TextPostProcessor.process("colon list") == ": List")
        // Single quotes, brackets, braces, dollar sign
        #expect(TextPostProcessor.process("open single quote hi close single quote")
                == "\u{2018}hi\u{2019}")
        #expect(TextPostProcessor.process("open bracket x close bracket") == "[x]")
        #expect(TextPostProcessor.process("open brace y close brace") == "{y}")
        #expect(TextPostProcessor.process("dollar sign 5") == "$5" || TextPostProcessor.process("dollar sign 5").contains("$"))
        #expect(TextPostProcessor.process("apostrophe s") == "\u{2019}s" || TextPostProcessor.process("apostrophe s").hasPrefix("\u{2019}"))
    }

    @Test("Spoken hashtag and @-mention glue")
    func spokenHashtagAndMention() {
        // hashtag + word → #word (no space)
        #expect(TextPostProcessor.process("hashtag chirp") == "#chirp")
        #expect(TextPostProcessor.process("tag hashtag chirp") == "tag #chirp")
        #expect(TextPostProcessor.process("pound sign openSource") == "#openSource")
        // at sign / at symbol + word → @word
        #expect(TextPostProcessor.process("at sign stefan") == "@stefan")
        #expect(TextPostProcessor.process("mail me at sign you") == "mail me @you")
        #expect(TextPostProcessor.process("ping at symbol alice") == "ping @alice")
        // "mention" alias
        #expect(TextPostProcessor.process("mention stefan") == "@stefan")
        #expect(TextPostProcessor.process("ping mention bob now") == "ping @bob now")
        // Bare "at" stays conversational (not a mention)
        #expect(TextPostProcessor.process("meet at noon") == "meet at noon")
        #expect(TextPostProcessor.process("look at this") == "look at this")
        // Email path must win over any at-mention glue
        #expect(TextPostProcessor.process("john at example dot com") == "john@example.com")
        #expect(TextPostProcessor.process("john underscore smith at example dot com")
                == "john_smith@example.com")
    }

    @Test("Spoken symbols slash asterisk underscore")
    func spokenSymbols() {
        // Mid-phrase slash keeps space before / when after a word ("docs /readme").
        #expect(TextPostProcessor.process("docs slash readme") == "docs /readme")
        #expect(TextPostProcessor.process("path forward slash bin") == "path /bin")
        #expect(TextPostProcessor.process("star asterisk note").contains("*"))
        #expect(TextPostProcessor.process("file underscore name").contains("_"))
        #expect(TextPostProcessor.process("a plus sign b").contains("+"))
        #expect(TextPostProcessor.process("x equals sign y").contains("="))
        #expect(TextPostProcessor.process("one half cup").contains("½"))
        #expect(TextPostProcessor.process("one fifth cup").contains("⅕"))
        #expect(TextPostProcessor.process("three eighths").contains("⅜"))
        #expect(TextPostProcessor.process("two and a half cups").contains("2½"))
        #expect(TextPostProcessor.process("one and a half") == "1½" || TextPostProcessor.process("one and a half").contains("1½"))
        #expect(TextPostProcessor.process("six and a half") == "6½")
        #expect(TextPostProcessor.process("ten and a half cups") == "10½ cups")
        #expect(TextPostProcessor.process("twenty two and a half") == "22½")
        #expect(TextPostProcessor.process("six and a quarter") == "6¼")
        #expect(TextPostProcessor.process("ten and three quarters") == "10¾")
        #expect(TextPostProcessor.process("twenty two and a quarter") == "22¼")
        #expect(TextPostProcessor.process("six and a third") == "6⅓")
        #expect(TextPostProcessor.process("ten and two thirds") == "10⅔")
        #expect(TextPostProcessor.process("six and three eighths") == "6⅜")
        #expect(TextPostProcessor.process("one hundred and two") == "102")
        #expect(TextPostProcessor.process("six and a fifth") == "6⅕")
        #expect(TextPostProcessor.process("six and three fifths") == "6⅗")
        #expect(TextPostProcessor.process("two and five sixths") == "2⅚")
        #expect(TextPostProcessor.process("two hundred and four") == "204")
        // Dozen compound must not stop at fraction rewrite
        #expect(TextPostProcessor.process("two and a half dozen") == "30")
        #expect(TextPostProcessor.process("two and a half dozen eggs") == "30 eggs")
        #expect(TextPostProcessor.process("a couple of minutes") == "2 minutes")
        #expect(TextPostProcessor.process("a pair of shoes") == "2 shoes")
        #expect(TextPostProcessor.process("site dot edu") == "site.edu")
        // Tilde at start of string (path prefix) and mid-phrase
        #expect(TextPostProcessor.process("tilde") == "~")
        #expect(TextPostProcessor.process("tilde slash bin") == "~/bin")
        #expect(TextPostProcessor.process("path tilde end").contains("~"))
    }

    @Test("Spoken path prefixes tilde home dot slash")
    func spokenPathPrefixes() {
        #expect(TextPostProcessor.process("tilde slash src") == "~/src")
        #expect(TextPostProcessor.process("tilde forward slash src") == "~/src")
        #expect(TextPostProcessor.process("home slash Documents") == "~/Documents")
        #expect(TextPostProcessor.process("home forward slash Documents") == "~/Documents")
        #expect(TextPostProcessor.process("dot slash foo") == "./foo")
        #expect(TextPostProcessor.process("dot forward slash foo") == "./foo")
        #expect(TextPostProcessor.process("open tilde slash .config") == "open ~/.config")
        #expect(TextPostProcessor.process("cd home slash src") == "cd ~/src")
        // Leading absolute path: "slash usr slash bin" → "/usr/bin"
        #expect(TextPostProcessor.process("slash usr slash bin") == "/usr/bin")
        #expect(TextPostProcessor.process("forward slash usr slash local") == "/usr/local")
        // Absolute path after a word: keep space before / ("cd /tmp", not "cd/tmp").
        #expect(TextPostProcessor.process("cd slash tmp") == "cd /tmp")
        #expect(TextPostProcessor.process("cd slash usr slash local") == "cd /usr/local")
        // Parent path: "dot dot slash" → "../"
        #expect(TextPostProcessor.process("dot dot slash src") == "../src")
        #expect(TextPostProcessor.process("dot dot forward slash src") == "../src")
        #expect(TextPostProcessor.process("cd dot dot slash lib") == "cd ../lib")
        // Must not break domain ITN
        #expect(TextPostProcessor.process("visit example dot com") == "visit example.com")
        #expect(TextPostProcessor.process("dot company").contains("company"))
        // Bare home / bare dot stay words
        #expect(TextPostProcessor.process("go home now") == "go home now")
        #expect(TextPostProcessor.process("the dot is here").contains("dot"))
        // Email / URL still work with path polish present
        #expect(TextPostProcessor.process("john at example dot com") == "john@example.com")
        #expect(TextPostProcessor.process("https colon slash slash example dot com")
                == "https://example.com")
    }

    @Test("Bullet list spoken commands")
    func bulletLists() {
        let r = TextPostProcessor.process("buy milk bullet point eggs next bullet bread")
        #expect(r.contains("•"), "expected bullets in \"\(r)\"")
        #expect(r.contains("eggs"))
        #expect(r.contains("bread"))
        // Avoid false positive on "bullet train"
        #expect(TextPostProcessor.process("bullet train arrives") == "bullet train arrives"
                || TextPostProcessor.process("bullet train arrives").contains("bullet train"))
    }

    @Test("Light ITN formats spoken times")
    func lightITN() {
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
        #expect(TextPostProcessor.process("Call me at 9 am") == "Call me at 9 a.m.")
        #expect(TextPostProcessor.process("see you at twelve p.m.") == "see you at 12 p.m.")
        // Non-time "one" must stay
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
    }

    @Test("Light ITN formats clock times with minutes")
    func lightITNClockMinutes() {
        let thirty = TextPostProcessor.process("Meeting at three thirty pm")
        #expect(thirty.contains("3:30"), "expected 3:30 in \"\(thirty)\"")
        #expect(thirty.contains("p.m.") || thirty.lowercased().contains("pm"),
                "expected pm/p.m. in \"\(thirty)\"")

        let dotted = TextPostProcessor.process("call at three thirty p.m.")
        #expect(dotted.contains("3:30"), "expected 3:30 in \"\(dotted)\"")

        let fifteen = TextPostProcessor.process("ten fifteen am")
        #expect(fifteen.contains("10:15"), "expected 10:15 in \"\(fifteen)\"")
        #expect(fifteen.contains("a.m.") || fifteen.lowercased().contains("am"),
                "expected am/a.m. in \"\(fifteen)\"")

        let compound = TextPostProcessor.process("arrive at two forty five pm")
        #expect(compound.contains("2:45"), "expected 2:45 in \"\(compound)\"")

        let ohFive = TextPostProcessor.process("leave at seven oh five am")
        #expect(ohFive.contains("7:05"), "expected 7:05 in \"\(ohFive)\"")

        let zeroFive = TextPostProcessor.process("leave at seven zero five am")
        #expect(zeroFive.contains("7:05"), "expected 7:05 in \"\(zeroFive)\"")

        // Digit form after cardinal ITN (or already-digit input)
        let digits = TextPostProcessor.process("meet at 3 30 pm")
        #expect(digits.contains("3:30"), "expected 3:30 in \"\(digits)\"")

        // Bare hour regression
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")

        // Non-times unchanged
        #expect(TextPostProcessor.process("meet at noon") == "meet at noon")
        #expect(TextPostProcessor.process("first of all") == "first of all")
    }

    @Test("Light ITN formats o'clock times")
    func lightITNOClock() {
        #expect(TextPostProcessor.process("three o'clock") == "3:00")
        #expect(TextPostProcessor.process("three oclock") == "3:00")
        #expect(TextPostProcessor.process("three o'clock pm") == "3:00 p.m.")
        #expect(TextPostProcessor.process("nine oclock a.m.") == "9:00 a.m.")
        #expect(TextPostProcessor.process("Meeting at twelve o'clock") == "Meeting at 12:00")
    }

    @Test("Light ITN half past and quarter past/to")
    func lightITNHalfQuarter() {
        #expect(TextPostProcessor.process("half past three") == "3:30")
        #expect(TextPostProcessor.process("half past three pm") == "3:30 p.m.")
        #expect(TextPostProcessor.process("half past 9 am") == "9:30 a.m.")
        #expect(TextPostProcessor.process("quarter past three") == "3:15")
        #expect(TextPostProcessor.process("a quarter past nine pm") == "9:15 p.m.")
        #expect(TextPostProcessor.process("quarter to four") == "3:45")
        #expect(TextPostProcessor.process("quarter to four am") == "3:45 a.m.")
        #expect(TextPostProcessor.process("quarter to one") == "12:45")
        #expect(TextPostProcessor.process("a quarter to twelve pm") == "11:45 p.m.")
        // Regressions
        #expect(TextPostProcessor.process("one half cup").contains("½") || TextPostProcessor.process("one half cup").contains("1/2")
            || TextPostProcessor.process("one half cup") == "½ cup"
            || TextPostProcessor.process("one half cup").contains("half"))
        #expect(TextPostProcessor.process("from three to five pm") == "from 3-5 p.m.")
        #expect(TextPostProcessor.process("three thirty pm") == "3:30 p.m.")
        #expect(TextPostProcessor.process("three o'clock") == "3:00")
    }

    @Test("Light ITN minutes past/to (British clock)")
    func lightITNMinutesPastTo() {
        // Must not be stolen by cardinal range ("ten to three" was "10-3")
        #expect(TextPostProcessor.process("ten to three") == "2:50")
        #expect(TextPostProcessor.process("ten to three pm") == "2:50 p.m.")
        #expect(TextPostProcessor.process("five past three") == "3:05")
        #expect(TextPostProcessor.process("five past three am") == "3:05 a.m.")
        #expect(TextPostProcessor.process("twenty past three") == "3:20")
        #expect(TextPostProcessor.process("twenty five to five") == "4:35")
        #expect(TextPostProcessor.process("twenty-five to five") == "4:35")
        #expect(TextPostProcessor.process("five to one") == "12:55")
        #expect(TextPostProcessor.process("ten to twelve pm") == "11:50 p.m.")
        // Cardinal ranges stay
        #expect(TextPostProcessor.process("from ten to twenty") == "from 10-20")
        #expect(TextPostProcessor.process("from three to five pm") == "from 3-5 p.m.")
        #expect(TextPostProcessor.process("half past three") == "3:30")
        #expect(TextPostProcessor.process("quarter to four") == "3:45")
    }

    @Test("Light ITN formats time ranges with shared meridiem")
    func lightITNTimeRanges() {
        // Optional "from" kept; range compact with ASCII hyphen; shared pm/am
        #expect(TextPostProcessor.process("from three to five pm") == "from 3-5 p.m.")
        #expect(TextPostProcessor.process("three to five p.m.") == "3-5 p.m.")
        #expect(TextPostProcessor.process("from nine to eleven am") == "from 9-11 a.m.")
        #expect(TextPostProcessor.process("two through four pm") == "2-4 p.m.")
        #expect(TextPostProcessor.process("one until three a.m.") == "1-3 a.m.")
        // Digit hours (after number ITN or already digits)
        #expect(TextPostProcessor.process("from 3 to 5 pm") == "from 3-5 p.m.")
        #expect(TextPostProcessor.process("3 to 5 p.m.") == "3-5 p.m.")
        // First side with minutes + shared meridiem
        #expect(TextPostProcessor.process("three thirty to five pm") == "3:30-5 p.m.")
        #expect(TextPostProcessor.process("from three thirty to five pm") == "from 3:30-5 p.m.")
        #expect(TextPostProcessor.process("2 45 to 6 pm") == "2:45-6 p.m.")
        // Dual meridiem
        #expect(TextPostProcessor.process("nine am to five pm") == "9 a.m.-5 p.m.")
        #expect(TextPostProcessor.process("from nine am to five pm") == "from 9 a.m.-5 p.m.")
        #expect(TextPostProcessor.process("9 a.m. to 5 p.m.") == "9 a.m.-5 p.m.")
        // Bare hour regression (must not break)
        #expect(TextPostProcessor.process("meeting at three pm") == "meeting at 3 p.m.")
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
        // Minutes / o'clock still work alongside ranges
        #expect(TextPostProcessor.process("three thirty pm") == "3:30 p.m.")
        #expect(TextPostProcessor.process("three o'clock") == "3:00")
    }

    @Test("Light ITN formats cardinal number ranges without am/pm")
    func lightITNCardinalRanges() {
        // Spoken bounds → digits with hyphen; keep optional "from"
        #expect(TextPostProcessor.process("from ten to twenty") == "from 10-20")
        #expect(TextPostProcessor.process("from 10 to 20") == "from 10-20")
        #expect(TextPostProcessor.process("10 to 20") == "10-20")
        #expect(TextPostProcessor.process("three through five") == "3-5")
        #expect(TextPostProcessor.process("one until ten") == "1-10")
        // Time ranges must NOT be stolen by cardinal ranges
        #expect(TextPostProcessor.process("from three to five pm") == "from 3-5 p.m.")
        #expect(TextPostProcessor.process("three to five p.m.") == "3-5 p.m.")
        #expect(TextPostProcessor.process("from 3 to 5 pm") == "from 3-5 p.m.")
        // Bare meeting time still works
        #expect(TextPostProcessor.process("meeting at three pm") == "meeting at 3 p.m.")
        #expect(TextPostProcessor.process("Meeting at three pm") == "Meeting at 3 p.m.")
    }

    @Test("Light ITN formats ratings N out of M as N/M")
    func lightITNRatings() {
        // Spoken → slash form
        #expect(TextPostProcessor.process("four out of five") == "4/5")
        #expect(TextPostProcessor.process("rated four out of five") == "rated 4/5")
        // Digits after SpokenNumberITN / already numeric
        #expect(TextPostProcessor.process("4 out of 5") == "4/5")
        #expect(TextPostProcessor.process("rated 4 out of 5") == "rated 4/5")
        // Optional trailing "stars" kept
        #expect(TextPostProcessor.process("four out of five stars") == "4/5 stars")
        #expect(TextPostProcessor.process("4 out of 5 stars") == "4/5 stars")
        // Teens / decades
        #expect(TextPostProcessor.process("ten out of ten") == "10/10")
        #expect(TextPostProcessor.process("nine out of ten") == "9/10")
        // Multi-digit after SpokenNumber (22 out of 100)
        #expect(TextPostProcessor.process("twenty two out of one hundred") == "22/100")
        #expect(TextPostProcessor.process("twenty out of twenty five") == "20/25")
        // Do not convert "out of order" without number bounds
        #expect(TextPostProcessor.process("out of order") == "out of order")
        #expect(TextPostProcessor.process("that is out of order") == "that is out of order")
        // Quantity nouns still convert bare units (regression)
        #expect(TextPostProcessor.process("five emails") == "5 emails")
        #expect(TextPostProcessor.process("ten items") == "10 items")
    }

    @Test("Light ITN N over M and N divided by M as N/M")
    func lightITNOverAndDividedBy() {
        #expect(TextPostProcessor.process("three over four") == "3/4")
        #expect(TextPostProcessor.process("twenty two over one hundred") == "22/100")
        #expect(TextPostProcessor.process("3 over 4") == "3/4")
        #expect(TextPostProcessor.process("ten over twenty") == "10/20")
        #expect(TextPostProcessor.process("three divided by four") == "3/4")
        #expect(TextPostProcessor.process("22 divided by 7") == "22/7")
        #expect(TextPostProcessor.process("one hundred divided by five") == "100/5")
        // Guards: prose "over" / "divided by" without numeric bounds
        #expect(TextPostProcessor.process("look over there") == "look over there")
        #expect(TextPostProcessor.process("over the hill") == "over the hill")
        #expect(TextPostProcessor.process("take over please") == "take over please")
        #expect(TextPostProcessor.process("the city was divided by war")
            == "the city was divided by war")
    }

    @Test("Light ITN math operators plus minus times equals")
    func lightITNMathOps() {
        #expect(TextPostProcessor.process("three plus four") == "3 + 4")
        #expect(TextPostProcessor.process("ten plus twenty") == "10 + 20")
        #expect(TextPostProcessor.process("22 plus 7") == "22 + 7")
        #expect(TextPostProcessor.process("ten minus three") == "10 - 3")
        #expect(TextPostProcessor.process("one hundred minus five") == "100 - 5")
        #expect(TextPostProcessor.process("three times four") == "3 × 4")
        #expect(TextPostProcessor.process("ten times twenty") == "10 × 20")
        #expect(TextPostProcessor.process("three multiplied by four") == "3 × 4")
        #expect(TextPostProcessor.process("five equals five") == "5 = 5")
        #expect(TextPostProcessor.process("ten equals ten") == "10 = 10")
        // Chain
        #expect(TextPostProcessor.process("three plus four equals seven") == "3 + 4 = 7")
        // Frequency must not become product
        #expect(TextPostProcessor.process("three times a day") == "3 times a day")
        #expect(TextPostProcessor.process("ten times a week") == "10 times a week")
        #expect(TextPostProcessor.process("five times an hour") == "5 times an hour")
        // Signed temperature still works
        #expect(TextPostProcessor.process("temperature is minus twenty")
            == "temperature is -20")
        #expect(TextPostProcessor.process("minus twenty") == "-20")
        // Prose guards
        #expect(TextPostProcessor.process("plus size") == "plus size"
            || TextPostProcessor.process("plus size").contains("plus"))
        #expect(TextPostProcessor.process("times are hard") == "times are hard")
    }

    @Test("Light ITN powers squared cubed and to the power of")
    func lightITNPowers() {
        #expect(TextPostProcessor.process("three squared") == "3²")
        #expect(TextPostProcessor.process("ten squared") == "10²")
        #expect(TextPostProcessor.process("four cubed") == "4³")
        #expect(TextPostProcessor.process("two cubed") == "2³")
        #expect(TextPostProcessor.process("two to the power of three") == "2³")
        #expect(TextPostProcessor.process("ten to the power of two") == "10²")
        #expect(TextPostProcessor.process("two to the power of ten") == "2¹⁰")
        #expect(TextPostProcessor.process("3 to the power of 4") == "3⁴")
        #expect(TextPostProcessor.process("two to the third power") == "2³")
        #expect(TextPostProcessor.process("ten to the fourth power") == "10⁴")
        // Guards
        #expect(TextPostProcessor.process("squared away") == "squared away")
        #expect(TextPostProcessor.process("back to the power of love")
            == "back to the power of love"
            || TextPostProcessor.process("back to the power of love").contains("power of"))
        #expect(TextPostProcessor.process("go to the store") == "go to the store")
    }

    @Test("Light ITN square root cube root absolute value")
    func lightITNRootsAndAbsolute() {
        #expect(TextPostProcessor.process("square root of nine") == "√9")
        #expect(TextPostProcessor.process("the square root of sixteen") == "√16")
        #expect(TextPostProcessor.process("square root of 25") == "√25")
        #expect(TextPostProcessor.process("square root of one hundred") == "√100")
        #expect(TextPostProcessor.process("cube root of eight") == "∛8")
        #expect(TextPostProcessor.process("the cube root of 27") == "∛27")
        #expect(TextPostProcessor.process("absolute value of five") == "|5|")
        #expect(TextPostProcessor.process("the absolute value of minus twenty") == "|-20|"
            || TextPostProcessor.process("the absolute value of minus twenty") == "|-20|")
        #expect(TextPostProcessor.process("absolute value of 10") == "|10|")
        // Guards — prose without a numeric bound
        #expect(TextPostProcessor.process("root of the problem") == "root of the problem")
        #expect(TextPostProcessor.process("absolute value of freedom")
            == "absolute value of freedom")
        #expect(TextPostProcessor.process("square root beer") == "square root beer"
            || TextPostProcessor.process("square root beer").contains("root"))
    }

    @Test("Light ITN scientific notation times ten to the")
    func lightITNScientificNotation() {
        #expect(TextPostProcessor.process("three times ten to the power of five") == "3×10⁵")
        #expect(TextPostProcessor.process("three times 10 to the power of five") == "3×10⁵")
        #expect(TextPostProcessor.process("3.5 times ten to the power of two") == "3.5×10²")
        #expect(TextPostProcessor.process("six times ten to the power of minus three") == "6×10⁻³")
        #expect(TextPostProcessor.process("two times ten to the fourth power") == "2×10⁴")
        #expect(TextPostProcessor.process("1.2 times 10 to the power of 3") == "1.2×10³")
        // Frequency / prose must not become sci notation
        #expect(TextPostProcessor.process("three times a day") == "3 times a day")
        #expect(TextPostProcessor.process("ten times twenty") == "10 × 20")
        // Bare power still works
        #expect(TextPostProcessor.process("ten to the power of minus two") == "10⁻²")
        #expect(TextPostProcessor.process("two to the power of minus three") == "2⁻³")
    }

    @Test("Light ITN e-notation and e to the power")
    func lightITNENotation() {
        #expect(TextPostProcessor.process("three e five") == "3e5")
        #expect(TextPostProcessor.process("3 e 5") == "3e5")
        #expect(TextPostProcessor.process("3.5 e 2") == "3.5e2")
        #expect(TextPostProcessor.process("six e minus three") == "6e-3")
        #expect(TextPostProcessor.process("1.2 e -4") == "1.2e-4")
        #expect(TextPostProcessor.process("two point five e ten") == "2.5e10")
        // Euler e^N
        #expect(TextPostProcessor.process("e to the power of two") == "e²")
        #expect(TextPostProcessor.process("e to the power of minus one") == "e⁻¹")
        #expect(TextPostProcessor.process("e to the third power") == "e³")
        // Guards
        #expect(TextPostProcessor.process("the letter e") == "the letter e")
        #expect(TextPostProcessor.process("email me") == "email me"
            || TextPostProcessor.process("email me").lowercased().contains("mail"))
        #expect(TextPostProcessor.process("give me the e") == "give me the e")
    }

    @Test("Light ITN Greek letters cued and 2 pi")
    func lightITNGreekLetters() {
        #expect(TextPostProcessor.process("letter alpha") == "α")
        #expect(TextPostProcessor.process("greek beta") == "β")
        #expect(TextPostProcessor.process("symbol gamma") == "γ")
        #expect(TextPostProcessor.process("letter capital delta") == "Δ")
        #expect(TextPostProcessor.process("greek capital sigma") == "Σ")
        #expect(TextPostProcessor.process("letter pi") == "π")
        #expect(TextPostProcessor.process("symbol theta") == "θ")
        #expect(TextPostProcessor.process("letter omega") == "ω")
        #expect(TextPostProcessor.process("letter capital omega") == "Ω")
        #expect(TextPostProcessor.process("letter mu") == "μ")
        #expect(TextPostProcessor.process("letter lambda") == "λ")
        // Common math: "two pi" / "2 pi"
        #expect(TextPostProcessor.process("two pi") == "2π")
        #expect(TextPostProcessor.process("2 pi") == "2π")
        #expect(TextPostProcessor.process("three pi r") == "3π r"
            || TextPostProcessor.process("three pi").contains("π"))
        // Guards — bare words stay prose
        #expect(TextPostProcessor.process("alpha male") == "alpha male")
        #expect(TextPostProcessor.process("beta release") == "beta release")
        #expect(TextPostProcessor.process("delta airlines") == "delta airlines"
            || TextPostProcessor.process("delta airlines").lowercased().contains("delta"))
        #expect(TextPostProcessor.process("pie chart") == "pie chart")
    }

    @Test("Light ITN limit as approaches")
    func lightITNLimitAs() {
        #expect(TextPostProcessor.process("limit as n approaches infinity") == "lim(n→∞)")
        #expect(TextPostProcessor.process("the limit as x approaches zero") == "lim(x→0)")
        #expect(TextPostProcessor.process("limit as n goes to ten") == "lim(n→10)")
        #expect(TextPostProcessor.process("limit as t tends to infinity") == "lim(t→∞)")
        #expect(TextPostProcessor.process("the limit as x approaches 1") == "lim(x→1)")
        // Guards
        #expect(TextPostProcessor.process("limit as soon as possible")
            == "limit as soon as possible")
        #expect(TextPostProcessor.process("approaches infinity") == "approaches ∞"
            || TextPostProcessor.process("approaches infinity") == "approaches infinity")
    }

    @Test("Light ITN math relations and letter accents")
    func lightITNRelationsAndAccents() {
        #expect(TextPostProcessor.process("not equal to") == "≠")
        #expect(TextPostProcessor.process("does not equal") == "≠")
        #expect(TextPostProcessor.process("approximately equal") == "≈")
        #expect(TextPostProcessor.process("approx equal to") == "≈")
        #expect(TextPostProcessor.process("less than or equal to") == "≤")
        #expect(TextPostProcessor.process("greater than or equal to") == "≥")
        #expect(TextPostProcessor.process("much greater than") == "≫")
        #expect(TextPostProcessor.process("much less than") == "≪")
        #expect(TextPostProcessor.process("proportional to") == "∝")
        #expect(TextPostProcessor.process("element of") == "∈")
        #expect(TextPostProcessor.process("not element of") == "∉")
        #expect(TextPostProcessor.process("symbol therefore") == "∴")
        #expect(TextPostProcessor.process("therefore sign") == "∴")
        #expect(TextPostProcessor.process("symbol because") == "∵")
        #expect(TextPostProcessor.process("double right arrow") == "⇒")
        #expect(TextPostProcessor.process("if and only if") == "⇔")
        #expect(TextPostProcessor.process("symbol for all") == "∀")
        #expect(TextPostProcessor.process("symbol there exists") == "∃")
        // Accents (single letter)
        #expect(TextPostProcessor.process("x hat") == "x̂")
        #expect(TextPostProcessor.process("v hat") == "v̂")
        #expect(TextPostProcessor.process("hat x") == "x̂")
        #expect(TextPostProcessor.process("x bar") == "x̄")
        #expect(TextPostProcessor.process("x vector") == "x⃗")
        #expect(TextPostProcessor.process("vector v") == "v⃗")
        #expect(TextPostProcessor.process("x tilde") == "x̃")
        // Guards
        #expect(TextPostProcessor.process("therefore I agree") == "therefore I agree")
        #expect(TextPostProcessor.process("because it works") == "because it works")
        #expect(TextPostProcessor.process("for all people") == "for all people")
        #expect(TextPostProcessor.process("hat check") == "hat check")
        #expect(TextPostProcessor.process("bar exam") == "bar exam")
    }

    @Test("Light ITN nabla partial gradient curl infinity")
    func lightITNCalcOperators() {
        #expect(TextPostProcessor.process("nabla") == "∇")
        #expect(TextPostProcessor.process("operator nabla") == "∇")
        #expect(TextPostProcessor.process("del operator") == "∇")
        #expect(TextPostProcessor.process("partial f") == "∂f")
        #expect(TextPostProcessor.process("partial of f") == "∂f")
        #expect(TextPostProcessor.process("partial of f with respect to x") == "∂f/∂x")
        #expect(TextPostProcessor.process("partial with respect to y") == "∂/∂y")
        #expect(TextPostProcessor.process("partial derivative with respect to t") == "∂/∂t")
        #expect(TextPostProcessor.process("gradient of f") == "∇f")
        #expect(TextPostProcessor.process("divergence of F") == "∇·F"
            || TextPostProcessor.process("divergence of f") == "∇·f")
        #expect(TextPostProcessor.process("curl of f") == "∇×f")
        #expect(TextPostProcessor.process("to infinity") == "to ∞")
        #expect(TextPostProcessor.process("approaches infinity") == "approaches ∞")
        // Guards
        #expect(TextPostProcessor.process("partial payment") == "partial payment")
        #expect(TextPostProcessor.process("delete the file") == "delete the file")
        #expect(TextPostProcessor.process("gradient of the hill") == "gradient of the hill")
    }

    @Test("Light ITN sum product integral from A to B")
    func lightITNAggregateFromTo() {
        #expect(TextPostProcessor.process("sum from one to ten") == "∑(1…10)")
        #expect(TextPostProcessor.process("sum from 1 to 100") == "∑(1…100)")
        #expect(TextPostProcessor.process("the sum from three to five") == "∑(3…5)")
        #expect(TextPostProcessor.process("sum from twenty to thirty") == "∑(20…30)")
        #expect(TextPostProcessor.process("product from one to ten") == "∏(1…10)")
        #expect(TextPostProcessor.process("the product from 2 to 5") == "∏(2…5)")
        #expect(TextPostProcessor.process("product from three to seven") == "∏(3…7)")
        #expect(TextPostProcessor.process("integral from zero to one") == "∫(0…1)")
        #expect(TextPostProcessor.process("the integral from 0 to 10") == "∫(0…10)")
        #expect(TextPostProcessor.process("integral from one to one hundred") == "∫(1…100)")
        // Guards
        #expect(TextPostProcessor.process("sum from here to there") == "sum from here to there")
        #expect(TextPostProcessor.process("product from design to ship")
            == "product from design to ship")
        #expect(TextPostProcessor.process("from one to ten") == "from 1-10"
            || TextPostProcessor.process("from one to ten").contains("1"))
    }

    @Test("Light ITN factorial and logarithms")
    func lightITNFactorialAndLog() {
        #expect(TextPostProcessor.process("five factorial") == "5!")
        #expect(TextPostProcessor.process("ten factorial") == "10!")
        #expect(TextPostProcessor.process("3 factorial") == "3!")
        #expect(TextPostProcessor.process("one hundred factorial") == "100!")
        #expect(TextPostProcessor.process("log of ten") == "log(10)")
        #expect(TextPostProcessor.process("the log of one hundred") == "log(100)")
        #expect(TextPostProcessor.process("logarithm of 10") == "log(10)")
        #expect(TextPostProcessor.process("natural log of ten") == "ln(10)")
        #expect(TextPostProcessor.process("natural log of five") == "ln(5)")
        #expect(TextPostProcessor.process("the natural logarithm of five") == "ln(5)")
        #expect(TextPostProcessor.process("ln of ten") == "ln(10)")
        #expect(TextPostProcessor.process("log base two of eight") == "log₂(8)")
        #expect(TextPostProcessor.process("log base 10 of 100") == "log₁₀(100)")
        // Guards
        #expect(TextPostProcessor.process("factorial design") == "factorial design")
        #expect(TextPostProcessor.process("log cabin") == "log cabin")
        #expect(TextPostProcessor.process("log of claims") == "log of claims")
    }

    @Test("Light ITN formats percent and dollars")
    func lightITNPercentCurrency() {
        #expect(TextPostProcessor.process("about 50 percent done") == "about 50% done")
        #expect(TextPostProcessor.process("fifty percent complete") == "50% complete")
        #expect(TextPostProcessor.process("one hundred percent ready") == "100% ready")
        #expect(TextPostProcessor.process("twenty five percent off") == "25% off")
        #expect(TextPostProcessor.process("50 per cent done") == "50% done")
        #expect(TextPostProcessor.process("twenty percent of fifteen") == "20% of 15")
        #expect(TextPostProcessor.process("costs 20 dollars") == "costs $20")
        #expect(TextPostProcessor.process("pay twenty dollars now") == "pay $20 now")
        #expect(TextPostProcessor.process("one dollar please").contains("$1"))
        // Bare numbers / words without unit stay put
        #expect(TextPostProcessor.process("one more thing") == "one more thing")
        #expect(TextPostProcessor.process("percent of cases") == "percent of cases")
    }

    @Test("Light ITN multi-currency euros pounds yen cents")
    func lightITNMultiCurrency() {
        #expect(TextPostProcessor.process("costs 20 euros") == "costs €20")
        #expect(TextPostProcessor.process("pay twenty euros now") == "pay €20 now")
        #expect(TextPostProcessor.process("costs 20 euro") == "costs €20")
        // Weight units win over currency for bare "pounds" ("20 pounds" → "20 lb").
        #expect(TextPostProcessor.process("costs 20 pounds") == "costs 20 lb")
        #expect(TextPostProcessor.process("pay twenty pound now") == "pay 20 lb now")
        #expect(TextPostProcessor.process("costs 20 yen") == "costs ¥20")
        #expect(TextPostProcessor.process("50 cents") == "50¢")
        #expect(TextPostProcessor.process("twenty cents") == "20¢")
        // Compound dollars + cents → $N.CC
        #expect(TextPostProcessor.process("20 dollars and 50 cents") == "$20.50")
        #expect(TextPostProcessor.process("twenty dollars and fifty cents") == "$20.50")
        #expect(TextPostProcessor.process("5 dollars and 5 cents") == "$5.05")
        // Existing dollars path still works after number ITN
        #expect(TextPostProcessor.process("costs one hundred dollars") == "costs $100")
    }

    @Test("Light ITN sterling currency via pounds sterling and quid")
    func lightITNSterlingCurrency() {
        // Bare pounds stay weight (lb); currency needs disambiguators.
        #expect(TextPostProcessor.process("costs 20 pounds") == "costs 20 lb")
        #expect(TextPostProcessor.process("costs 20 pounds sterling") == "costs £20")
        #expect(TextPostProcessor.process("costs 20 pound sterling") == "costs £20")
        #expect(TextPostProcessor.process("costs 20 quid") == "costs £20")
        // Spoken numbers → digits then sterling
        #expect(TextPostProcessor.process("pay twenty quid now") == "pay £20 now")
        #expect(TextPostProcessor.process("twenty pounds sterling") == "£20")
        #expect(TextPostProcessor.process("one hundred pounds sterling") == "£100")
    }

    @Test("Light ITN street suffix abbreviations after street number")
    func lightITNStreetSuffixes() {
        #expect(TextPostProcessor.process("35 Lexington avenue") == "35 Lexington Ave.")
        #expect(TextPostProcessor.process("141 Dorchester street") == "141 Dorchester St.")
        #expect(TextPostProcessor.process("10 Main road") == "10 Main Rd.")
        #expect(TextPostProcessor.process("22 Oak drive") == "22 Oak Dr.")
        #expect(TextPostProcessor.process("5 Sunset boulevard") == "5 Sunset Blvd.")
        #expect(TextPostProcessor.process("8 Maple lane") == "8 Maple Ln.")
        // Avoid "Court court" — repetition dedup collapses case-insensitive repeats first.
        #expect(TextPostProcessor.process("3 Baker court") == "3 Baker Ct.")
        #expect(TextPostProcessor.process("12 Park place") == "12 Park Pl.")
        #expect(TextPostProcessor.process("7 Elm circle") == "7 Elm Cir.")
        #expect(TextPostProcessor.process("101 State highway") == "101 State Hwy.")
        // Plural spoken forms
        #expect(TextPostProcessor.process("2 Side streets") == "2 Side St.")
        // Multi-word street names + title-case
        #expect(TextPostProcessor.process("35 North Main avenue") == "35 North Main Ave.")
        #expect(
            TextPostProcessor.process("100 martin luther king boulevard")
                == "100 Martin Luther King Blvd."
        )
        #expect(TextPostProcessor.process("10 oak tree lane") == "10 Oak Tree Ln.")
        // No street number → leave alone ("hit the road")
        #expect(TextPostProcessor.process("hit the road") == "hit the road")
        #expect(TextPostProcessor.process("go down the street") == "go down the street")
    }

    @Test("Light ITN city title-case after street abbrev")
    func lightITNCityTitleCaseAfterStreet() {
        #expect(
            TextPostProcessor.process("35 Lexington avenue boston massachusetts")
                == "35 Lexington Ave. Boston MA"
        )
        #expect(
            TextPostProcessor.process("141 Dorchester street san francisco california")
                == "141 Dorchester St. San Francisco CA"
        )
        #expect(
            TextPostProcessor.process("10 Main road chicago illinois zip code 60601")
                == "10 Main Rd. Chicago IL 60601"
        )
        // No street cue → bare city not force-title-cased mid-prose
        #expect(TextPostProcessor.process("went to boston for coffee") == "went to boston for coffee")
    }

    @Test("Light ITN US state names to USPS abbreviations")
    func lightITNStateAbbreviations() {
        // Multi-word: always convert (low FP); longest match first
        #expect(TextPostProcessor.process("new york") == "NY")
        #expect(TextPostProcessor.process("new jersey") == "NJ")
        #expect(TextPostProcessor.process("new mexico") == "NM")
        #expect(TextPostProcessor.process("north carolina") == "NC")
        #expect(TextPostProcessor.process("south carolina") == "SC")
        #expect(TextPostProcessor.process("north dakota") == "ND")
        #expect(TextPostProcessor.process("south dakota") == "SD")
        #expect(TextPostProcessor.process("west virginia") == "WV")
        #expect(TextPostProcessor.process("rhode island") == "RI")
        #expect(TextPostProcessor.process("district of columbia") == "DC")
        #expect(TextPostProcessor.process("I love new york") == "I love NY")
        // Single-word bare / casual prose: leave alone (high FP without address cue)
        #expect(TextPostProcessor.process("california") == "california")
        #expect(TextPostProcessor.process("TEXAS") == "TEXAS")
        #expect(TextPostProcessor.process("Massachusetts") == "Massachusetts")
        #expect(TextPostProcessor.process("washington") == "washington")
        #expect(TextPostProcessor.process("I love california") == "I love california")
        #expect(TextPostProcessor.process("lives in Florida now") == "lives in Florida now")
        #expect(TextPostProcessor.process("visit georgia") == "visit georgia")
        #expect(TextPostProcessor.process("maine is cold") == "maine is cold")
        // Single-word with street suffix cue (street ITN → Ave. then state)
        #expect(
            TextPostProcessor.process("35 Lexington avenue california")
                == "35 Lexington Ave. CA"
        )
        #expect(
            TextPostProcessor.process("141 Dorchester street massachusetts")
                == "141 Dorchester St. MA"
        )
        // Single-word after ZIP cue (left of match)
        #expect(TextPostProcessor.process("90210 california") == "90210 CA")
        #expect(TextPostProcessor.process("zip code 90210 california") == "90210 CA")
        // "state of" cue
        #expect(TextPostProcessor.process("in the state of maine") == "in the state of ME")
        #expect(TextPostProcessor.process("state of Washington") == "state of WA")
        // Partial / non-state tokens stay
        #expect(TextPostProcessor.process("carolina") == "carolina")
        #expect(TextPostProcessor.process("york") == "york")
    }

    @Test("Light ITN ZIP codes")
    func lightITNZIPCodes() {
        // Strip spoken "zip code" / "zip" prefix before digits
        #expect(TextPostProcessor.process("zip code 90210") == "90210")
        #expect(TextPostProcessor.process("zip 90210") == "90210")
        #expect(TextPostProcessor.process("ZIP CODE 90210") == "90210")
        // ZIP+4 spaced digits → hyphenated
        #expect(TextPostProcessor.process("90210 1234") == "90210-1234")
        #expect(TextPostProcessor.process("zip code 90210 1234") == "90210-1234")
        // Bare 5-digit ZIP stays
        #expect(TextPostProcessor.process("mail to 90210 please") == "mail to 90210 please")
    }

    @Test("Light ITN combined street + state address")
    func lightITNAddressCombined() {
        #expect(
            TextPostProcessor.process("35 Lexington avenue california")
                == "35 Lexington Ave. CA"
        )
        #expect(
            TextPostProcessor.process("141 Dorchester street massachusetts zip code 02125")
                == "141 Dorchester St. MA 02125"
        )
    }

    @Test("Light ITN suite / room / extension labels with digits")
    func lightITNSuiteRoomExtensionDigits() {
        #expect(TextPostProcessor.process("suite 12") == "Suite 12")
        #expect(TextPostProcessor.process("Suite 12") == "Suite 12")
        #expect(TextPostProcessor.process("room 101") == "Room 101")
        #expect(TextPostProcessor.process("extension 55") == "ext. 55")
        #expect(TextPostProcessor.process("ext 55") == "ext. 55")
        #expect(TextPostProcessor.process("ext. 55") == "ext. 55")
        #expect(TextPostProcessor.process("apt 4") == "Apt. 4")
        #expect(TextPostProcessor.process("apartment 12") == "Apt. 12")
        #expect(TextPostProcessor.process("unit 3") == "Unit 3")
        #expect(TextPostProcessor.process("floor 5") == "Floor 5")
        // Cue without a number stays put
        #expect(TextPostProcessor.process("hit the room") == "hit the room")
        #expect(TextPostProcessor.process("nice suite") == "nice suite")
        // Mid-phrase content after digits: do not force Suite/Room label
        #expect(TextPostProcessor.process("room 5 people") == "room 5 people")
        #expect(TextPostProcessor.process("suite 12 is large") == "suite 12 is large")
        // Address-adjacent still rewrites (comma / state / ZIP / EOS)
        #expect(TextPostProcessor.process("suite 12,") == "Suite 12,")
        #expect(TextPostProcessor.process("Room 101 CA") == "Room 101 CA")
        #expect(TextPostProcessor.process("suite 12 90210") == "Suite 12 90210")
    }

    @Test("Light ITN suite / room with spoken digit runs after cue")
    func lightITNSuiteRoomSpokenDigits() {
        // Single digit after cue force-converts (suite five → Suite 5)
        #expect(TextPostProcessor.process("suite five") == "Suite 5")
        #expect(TextPostProcessor.process("room one") == "Room 1")
        // Short digit runs (≥2) force-convert after address cues only
        #expect(TextPostProcessor.process("suite five five") == "Suite 55")
        #expect(TextPostProcessor.process("room one zero one") == "Room 101")
        #expect(TextPostProcessor.process("extension five five") == "ext. 55")
        #expect(TextPostProcessor.process("unit two five") == "Unit 25")
        // Floor cue (same as suite/room)
        #expect(TextPostProcessor.process("floor five") == "Floor 5")
        #expect(TextPostProcessor.process("floor five five") == "Floor 55")
        // Compounds already digits via SpokenNumberITN, then label
        #expect(TextPostProcessor.process("suite twenty five") == "Suite 25")
        // Uncued short runs stay words (phone min length still 3)
        #expect(TextPostProcessor.process("five five") == "five five")
        // Phone / ZIP still work
        #expect(TextPostProcessor.process("five five five one two one two") == "555-1212")
        #expect(TextPostProcessor.process("zip code 90210") == "90210")
    }

    @Test("Light ITN version cue → vN / vN.M")
    func lightITNVersionNumbers() {
        #expect(TextPostProcessor.process("version two") == "v2")
        #expect(TextPostProcessor.process("version 3") == "v3")
        #expect(TextPostProcessor.process("version one point two") == "v1.2")
        #expect(TextPostProcessor.process("version one point five") == "v1.5")
        #expect(TextPostProcessor.process("ship version two soon") == "ship v2 soon")
        // Prose: no number after "version" stays unchanged
        #expect(TextPostProcessor.process("the version is fine") == "the version is fine")
        #expect(TextPostProcessor.process("version of the product") == "version of the product")
        // Suite path still works (must not steal "version")
        #expect(TextPostProcessor.process("suite five") == "Suite 5")
    }

    @Test("PackAcronyms min length via full process")
    func packAcronymsMinLengthInProcess() {
        #expect(TextPostProcessor.process("a b") == "a b")
        #expect(TextPostProcessor.process("i d") == "ID")
        #expect(TextPostProcessor.process("a i") == "AI")
        #expect(TextPostProcessor.process("a p i") == "API")
        // "I a" is not an allowlisted pair (and capital I is multi-meaning)
        #expect(TextPostProcessor.process("I a") == "I a")
    }

    @Test("Light ITN compact unit abbreviations after numbers")
    func lightITNUnits() {
        #expect(TextPostProcessor.process("5 miles") == "5 mi")
        #expect(TextPostProcessor.process("five miles") == "5 mi")
        #expect(TextPostProcessor.process("about 3.5 miles left") == "about 3.5 mi left")
        #expect(TextPostProcessor.process("10 kilometers") == "10 km")
        #expect(TextPostProcessor.process("ten kilometres") == "10 km")
        #expect(TextPostProcessor.process("ten feet") == "10 ft")
        #expect(TextPostProcessor.process("1 foot") == "1 ft")
        #expect(TextPostProcessor.process("2 inches") == "2 in")
        #expect(TextPostProcessor.process("one inch") == "1 in")
        #expect(TextPostProcessor.process("5 pounds") == "5 lb")
        #expect(TextPostProcessor.process("2 kilograms") == "2 kg")
        // Bare unit without a number stays put
        #expect(TextPostProcessor.process("I walked miles") == "I walked miles")
        #expect(TextPostProcessor.process("feet of snow") == "feet of snow")
    }

    @Test("Light ITN height feet-inches composite")
    func lightITNHeight() {
        // Compact feet'inches"
        #expect(TextPostProcessor.process("five foot ten") == "5'10\"")
        #expect(TextPostProcessor.process("5 feet 10 inches") == "5'10\"")
        #expect(TextPostProcessor.process("six foot two inches") == "6'2\"")
        #expect(TextPostProcessor.process("six foot two") == "6'2\"")
        #expect(TextPostProcessor.process("5 ft 10 in") == "5'10\"")
        #expect(TextPostProcessor.process("he is five foot eleven tall") == "he is 5'11\" tall")
        // Bare feet alone still abbreviates (not composite)
        #expect(TextPostProcessor.process("ten feet") == "10 ft")
        #expect(TextPostProcessor.process("1 foot") == "1 ft")
    }

    @Test("Light ITN temperature scale after degrees")
    func lightITNTemperature() {
        #expect(TextPostProcessor.process("72 degrees fahrenheit") == "72°F")
        #expect(TextPostProcessor.process("72 degrees celsius") == "72°C")
        #expect(TextPostProcessor.process("about 100 degrees Fahrenheit outside")
            == "about 100°F outside")
        // Plain degrees (no scale) still → °
        #expect(TextPostProcessor.process("90 degrees") == "90°")
        #expect(TextPostProcessor.process("ninety degrees") == "90°")
        // Spoken multi-word numbers before degrees (after SpokenNumberITN)
        #expect(TextPostProcessor.process("seventy two degrees fahrenheit") == "72°F")
        #expect(TextPostProcessor.process("seventy two degrees celsius") == "72°C")
        #expect(TextPostProcessor.process("one hundred degrees fahrenheit") == "100°F")
        // Scale without explicit "degrees"
        #expect(TextPostProcessor.process("72 fahrenheit") == "72°F")
        #expect(TextPostProcessor.process("72 celsius") == "72°C")
        #expect(TextPostProcessor.process("seventy two fahrenheit") == "72°F")
    }

    @Test("Does not drop bare function words as whole utterance")
    func keepsBareFunctionWords() {
        // Early VAD endpoints can decode a single onset word; dropping it loses speech.
        #expect(TextPostProcessor.process("the") == "the")
        #expect(TextPostProcessor.process("a") == "a")
        #expect(TextPostProcessor.process("to") == "to")
    }
}
