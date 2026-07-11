# Audio Pipeline

Hold a hotkey, talk, release — words appear in the focused app.

The recognizer (Parakeet TDT) is offline and fast, but not streaming —
it transcribes a complete audio buffer in one shot. It can't tell you
"the user is still talking" or "speech just ended." That's the VAD's
job: detect speech boundaries so we can feed the recognizer bounded
chunks mid-recording (committed segments) and know when silence means
"done with this phrase." pendingAudio exists because the VAD trims its
segments to detected speech boundaries, which can clip the start — so
peek and flush transcribe the raw buffer instead.


## Quality tests (generated audio → ranked WER)

Corpus pipeline tests synthesize speech with macOS `say`, convert to
16 kHz mono Float32, feed the real offline pipeline in ~85 ms chunks,
score each phrase with word/character error rate, and rank the corpus.

```
# Always-on fixture smoke (hello_world.wav; skips if model missing):
bazel test //:FixtureASRTests --test_output=errors
# Full TTS corpus (manual — not in default //... without --test_tag_filters):
bazel test //:AudioCorpusPipelineTests --test_output=all
# or the broader suite (same harness + older integration cases):
bazel test //:TranscriberIntegrationTests --test_output=all
```

| Piece | Role |
|---|---|
| `SpeechAudioGenerator` | TTS (`say` + `afconvert`), noise, silence, WAV load |
| `TranscriptionScoring` | WER / majorWER / CER + ranked leaderboard |
| `FixtureASRTests` | Always-on WAV smoke: hard WER when model present |
| `AudioCorpusPipelineTests` | Generate → pipe → score → assert budgets (manual) |

Coverage:

- **Clean corpus** — 16 golden phrases, mean majorWER ≤ 8%, WER ≤ 12%, CER ≤ 8%, median ≤ 5%, RTF ≤ 0.5
- **AppState E2E** — MockAudioRecorder → typed text, ranked subset
- **Silence** — no hallucination (WER 0 against empty ref)
- **Noisy** — 15 dB SNR, 6 phrases, mean majorWER ≤ 40%, WER ≤ 55%
- **Fixture WAV** — committed `hello_world.wav`
- **Multi-utterance** — two phrases + silence via AppState + SegmentJoiner
- **Spoken punctuation** — “period” / “question mark” / … rewrite hits
- **Continuous stream** — mid-session VAD commits, full-session rank
- **Multi-voice** — same phrase across system voices
- **Ranked report** — compact leaderboard for CI logs
- **ITN numbers** — TTS → ASR → light ITN (times, %, $, cardinals); ranked WER + digit hits
- **ITN dates** — month/day/weekday/relative dates with pinned clock; ranked
- **ITN lists** — numbered + bullet voice commands; marker hit rate + ranked content
- **AppState ITN E2E** — full pipeline typed text for ITN phrases
- **Master ranked report** — clean + ITN phrases in one leaderboard

Scoring helpers live in `Tests/ChirpTests/TranscriptionScoring.swift`
(always-on unit tests via `//:TextTests`).
Decode uses `withSpeechWindow` (lead+trail energy trim with 200ms rolls;
adaptive RMS noise floor so noisy rooms do not inflate speechFrameCount).
Constants live in `DecodePolicy` (dual-tested with `TranscriberBuffer.tla`).
Pipeline rebuild deferral: `PipelineRebuildDecision` + `PipelineRebuild.tla`.
ASR EP selection: `InferenceProvider` defaults to CPU (CoreML often slower
for Parakeet int8 via sherpa). Override with `CHIRP_ASR_PROVIDER=coreml`.
VAD stays on CPU.
Batch post-process (T5/LLM / Offline+Fixup): mid-session feed returns no
typed segments; flush joins with `SegmentJoiner`, post-processes once, and
AppState types a single delta (`EditStack.FlushReplace`).
Multi-utterance joins use `SegmentJoiner` (insert ". " when a new
capitalized clause follows bare text; suppress before proper nouns /
dict products like GitHub). Light ITN: times (`three pm`→`3 p.m.`,
`three thirty pm`→`3:30 p.m.`, `three o'clock`→`3:00`, time ranges with shared
meridiem: `from three to five pm`→`from 3-5 p.m.`, `three to five p.m.`→`3-5 p.m.`,
`two through four pm` / `one until three a.m.` same form; first-side minutes
`three thirty to five pm`→`3:30-5 p.m.`; dual meridiem `nine am to five pm`→
`9 a.m.-5 p.m.`; cardinal ranges without am/pm after time ranges:
`from ten to twenty` / `from 10 to 20`→`from 10-20`, `10 to 20`→`10-20`;
time ranges still win over cardinals), ratings
(`four out of five` / `4 out of 5`→`4/5`, `four out of five stars`→`4/5 stars`;
`out of order` stays), spoken cardinals
(`one hundred`→`100`, `twenty five`→`25`, `three point five`→`3.5`,
`five emails`/`ten items`→`5 emails`/`10 items` via quantity nouns;
`three times a day`/`ten times a week`/`three times per day`→digits;
`once a day`→`1 time a day`, `twice a week`→`2 times a week`
(not bare `three times` / `once more`); bare `one more thing` stays), ordinals
(`twenty first`→`21st`, `first of all` stays), dates (`march fifth twenty
twenty four`→`March 5, 2024`, `tomorrow`/`next monday` → absolute dates,
weekdays → `Monday`, bare `may I` stays), `50 percent`→`50%`, currency multi
(`20 dollars`→`$20`, `20 euros`→`€20`, `20 yen`→`¥20`, `50 cents`→`50¢`,
`20 dollars and 50 cents`→`$20.50`; bare `20 pounds`→`20 lb` weight;
`20 pounds sterling` / `20 quid`→`£20`), compact units after numbers
(`5 miles`→`5 mi`, `ten feet`→`10 ft`, `2 inches`→`2 in`), height composite
(`five foot ten` / `5 feet 10 inches`→`5'10"`; bare `ten feet` still→`10 ft`),
temperature (`72 degrees fahrenheit` / `seventy two degrees fahrenheit` /
`72 fahrenheit`→`72°F`; `90 degrees`→`90°`), street suffixes after a house number
(`35 Lexington avenue`→`35 Lexington Ave.`; multi-word names
`100 martin luther king boulevard`→`100 Martin Luther King Blvd.`;
`hit the road` stays), suite/room/
floor/apt/unit/extension (`suite 12`→`Suite 12`, `room 101`→`Room 101`,
`floor 5`→`Floor 5`, `extension 55` / `ext 55`→`ext. 55`, `apt 4`→`Apt. 4`;
spoken digit runs after these cues (min length 1): `suite five`→`Suite 5`,
`suite five five`→`Suite 55`, `floor five five`→`Floor 55`; `hit the room` stays;
end-of-phrase only — `room 5 people` stays plain),
version numbers (`version two`→`v2`, `version 3`→`v3`,
`version one point two`→`v1.2`; prose `the version is fine` stays — cue needs a number), US states →
USPS codes (multi-word always: `new york`→`NY`; single-word only with address
cue left of match — street abbrev, ZIP, or `state of` — so `I love california`
stays, `35 Lexington avenue california`→`35 Lexington Ave. CA`,
`state of maine`→`state of ME`), city title-case after street abbrev
(`… Ave. boston MA`→`… Ave. Boston MA`; multi-word `san francisco`→`San Francisco`)
and ZIP (`zip code 90210`→`90210`,
`90210 1234`→`90210-1234`).
Bare `one`/`two` stay words. Digit runs (≥3 single digits) concatenate for
phones (`five five five one two one two`→`555-1212`; 10-digit `XXX-XXX-XXXX`;
11-digit leading-1 `1-XXX-XXX-XXXX`; `oh`→`0`; short uncued `five five` stays).
Negatives: `minus twenty` /
`negative five`→`-20`/`-5` (not bare `minus` or `minus the …`). Spoken email:
`john at example dot com`→`john@example.com`, multi-dot
`john at mail dot google dot com`→`john@mail.google.com` (requires `dot`; bare
`meet at noon` stays); local connectors `underscore`/`dot`/`plus`→`_`/`.`/`+`
(`john underscore smith at example dot com`→`john_smith@example.com`).
Spoken URLs: `www dot example dot com`→`www.example.com`,
`w w w` / `double you double you double you`→`www`,
`https colon slash slash`→`https://` (and `http` / `forward slash` variants).
Spoken symbols: `slash`→`/`, `asterisk`→`*`,
`underscore`→`_`, fractions `one half`→`½`.
Spoken path prefixes (before stutter collapse):
`tilde slash` / `home slash`→`~/`, `dot slash`→`./` (not `dot com`),
`dot dot slash`→`../`, leading `slash` / `forward slash`→`/`
(e.g. `slash usr slash bin`→`/usr/bin`; after a word keeps space:
`cd slash tmp`→`cd /tmp`, not `cd/tmp`),
bare `tilde`→`~` (e.g. `open tilde slash .config`→`open ~/.config`).
Social tags: `hashtag chirp`→`#chirp`, `at sign stefan` / `mention stefan`→`@stefan`
(email `john at example dot com` still wins; bare `at` stays conversational).
Lists: `bullet point` /
`next bullet` → `•`; `number one` / `next number` → `1.` / `2.`;
`end list` resets numbering. Session list counter resets each recording.
Relative dates use the local timezone. Settings → Audio → Auto-Formatting
toggles relative dates, numbered lists, and bullets. Spoken terminal punct
works mid-segment (`hello period next` → `hello. Next`) with content-word
guards.
Spoken `new line` / `new paragraph` rewrite in `TextPostProcessor`;
newlines type as Return keys via `TextInserter.steps`. Custom vocabulary: `DictationDictionary`
(built-in tech ASR seeds + UserDefaults `chirp.dictationDictionary`).
Spoken edit commands (`DictationCommand` + `EditCommands.tla`):
- **scratch that** / **correct that** — multi-level undo (`EditStack`)
- **replace that** — next phrase replaces last (text stays until then; HUD “Replace…”)
- **replace X with Y** / **change X to Y** / **swap X for Y** — replace last case-insensitive occurrence of X with Y in the session buffer (select + type-over in host; `ReplacePhrase.tla`). No match → no-op. Does **not** steal bare **replace that**
- **delete X** / **remove X** — delete last case-insensitive occurrence of phrase X (absorbs one adjacent space; `DeletePhrase.tla`). No match → no-op. Does **not** steal **delete that** / **delete last word** / unit deletes
- **select X** / **highlight X** — select last case-insensitive occurrence of phrase X and arm type-over (`SelectPhrase.tla`). Buffer unchanged until next content. No match → no-op. Does **not** steal **select that** / **select last word** / unit selects
- **go to X** / **move to X** / **jump to X** — move caret to start of last occurrence of X (nav only; no type-over arm; next content still appends). `GoToPhrase.tla`
- **go after X** / **move after X** — move caret to end of last occurrence of X. Does **not** steal **go to start** / **go to next sentence**
- **redo that** — restore last scratched / word-deleted segment
- **delete last word** — drop trailing word (stack-aware; redo restores)
- **delete last two words** / **delete previous 3 words** / **delete the last four words** — drop last N words (N ≥ 2; spoken or digits)
- **delete previous word** / **delete prior word** — delete previous word (⇧⌥← then ⌫; keyboard only; buffer unchanged). Does **not** steal **delete last word** or **delete previous sentence**
- **delete last sentence** / **delete previous sentence** / **delete sentence** — drop trailing sentence (stack-aware; redo restores). Does **not** steal **delete last word** or **delete that**
- **delete first sentence** / **delete the first sentence** — drop first sentence (+ separator). Does **not** steal **delete last sentence**
- **delete last paragraph** / **delete previous paragraph** / **delete paragraph** — drop trailing paragraph (stack-aware; redo restores)
- **delete first paragraph** / **delete the first paragraph** — drop first paragraph (+ separator)
- **delete next paragraph** / **delete forward paragraph** — progressive: remove next paragraph from session cursor (from end = second). Trailing peel stack-aware; middle surgery clears stack. Resets paragraph nav index. Does **not** steal **delete last paragraph**
- **delete last line** / **delete previous line** / **delete line** — drop trailing line content after last `\n` (stack-aware; redo restores). Trailing empty line (`…\n`) peels the newline (not a no-op)
- **delete first line** / **delete the first line** — drop first line (+ newline)
- **delete next line** / **delete forward line** — progressive: remove next line from session cursor (from end = second). Does **not** steal **delete last line**
- **caps on / all caps on / no caps on** — sticky casing (`CapsMode`)
- **caps off** — back to normal casing
- **spell mode** / **start spelling** / **spell on** — sticky spell mode (`SpellMode`); packs letters / NATO / digits
- **spell off** / **end spelling** / **dictation mode** — exit spell mode
- **spell that** / **spell it** / **spell last** — select last phrase + enter spell mode (does not delete). Next content type-overwrites the selection and peels the session suffix (`SelectionCommit.tla`)
- **spell as a b c** — one-shot pack (`SpellTransform.oneShot`); does not enable sticky spell mode
  (e.g. `spell as capital j o h n` → `John`)
- Spoken single-letter runs pack to uppercase acronyms without sticky spell (`a p i` → `API` via `SpellTransform.packAcronyms`; min run 3, plus common 2-letter allowlist `i d`→`ID` / `u i`→`UI` / `a i`→`AI`; unlisted pairs like `a b` stay; `I a` stays)
- **no space on** / **compound on** / **no spaces on** — sticky no-space mode (`NoSpaceMode`); glues segments with empty separator (HUD “no space”); does **not** pack letters
- **no space off** / **compound off** / **spaces on** — exit no-space mode
- **cap that / all caps that / no caps that** — transform last word
- **cap next** / **capitalize next** / **caps next** — arm one-shot: next content’s first word is capitalized, then arm clears (`CapNext.tla`; HUD “cap next”)
- **title case that** — title-case last phrase (stack delta)
- **sentence case that** — sentence-case last phrase
- **no space that** — join last word without leading space
- **select that** / **highlight that** — select last phrase (shift+left). Next content **replaces** the selection in both host and session buffer (`SelectionCommit.tla`); **unselect that** / format that clears the arm so next speech appends again
- **select first / next / previous sentence** (and paragraph / line) — same replace-on-next-content contract for middle ranges (splice, not append)
- **select last word** — select trailing word only (same replace-on-next-content contract)
- **select next word** / **select forward word** — select next word (⇧⌥→; keyboard only; buffer unchanged)
- **select previous word** / **select prior word** — select trailing session word and arm type-over (same span as **select last word**; `SelectionCommit.tla`). Does **not** steal bare **previous word** (move left)
- **select previous N words** — select trailing N session words and arm type-over (same as **select last N words** when at session end)
- **delete next word** / **delete forward word** — delete next word (⇧⌥→ then ⌫; keyboard only; buffer unchanged). Does **not** steal **delete last word**
- **delete previous N characters** / **delete last N characters** — peel N trailing session characters (+ keyboard ⌫ when incremental). Single: **delete previous character**
- **delete next N characters** — select forward N then ⌫ (keyboard only)
- **select previous N characters** / **select next N characters** — ⇧← / ⇧→ × N (keyboard only; Voice Control style)
- **select last sentence** / **select sentence** — select trailing sentence
- **select previous sentence** / **select prior sentence** — progressive: from end select last; further calls step back (`SentenceCursor.tla`). Buffer unchanged
- **select first sentence** / **select the first sentence** / **highlight first sentence** / **select 1st sentence** — select first sentence (← session then ⇧→ × n). Buffer unchanged
- **select next sentence** / **select forward sentence** / **highlight next sentence** — progressive: from end select second sentence; further calls collapse prior selection then advance. **select first/last** set `sentenceNavIndex`. Buffer unchanged. Does **not** steal bare **next sentence** (move) or **select last sentence**
- **delete next sentence** / **delete forward sentence** — progressive: remove next sentence from session cursor (from end = second). When target is last, stack-aware trailing peel; else middle string surgery (stack cleared). Resets sentence nav index. Does **not** steal **delete last sentence** / **delete previous sentence**
- **select last paragraph** / **select paragraph** — select trailing paragraph
- **select previous paragraph** / **select prior paragraph** — progressive: from end select last; further step back (`ParagraphCursor.tla`)
- **select first paragraph** / **select the first paragraph** / **highlight first paragraph** / **select 1st paragraph** — select first paragraph (← session then ⇧→ × n). Buffer unchanged
- **select next paragraph** / **select forward paragraph** / **highlight next paragraph** — progressive: from end select second paragraph; further calls advance (collapse prior selection first). Buffer unchanged (`ParagraphCursor.tla`). Does **not** steal **select last paragraph**
- **previous paragraph** / **go to previous paragraph** / **back a paragraph** — progressive move to previous paragraph start. Buffer unchanged (`ParagraphCursor.tla`)
- **next paragraph** / **go to next paragraph** / **forward a paragraph** — progressive move to next paragraph start (from end = second). Buffer unchanged (`ParagraphCursor.tla`). Does **not** steal **select next paragraph**
- **select last line** / **select line** / **select this line** — select trailing line (content after last `\n`)
- **select previous line** / **select prior line** — progressive: from end select last; further step back (`LineCursor.tla`)
- **select first line** / **select the first line** / **highlight first line** / **select 1st line** — select first line (← session then ⇧→ × n; content before first `\n`). Buffer unchanged. Does **not** steal **select last line**
- **select next line** / **select forward line** / **highlight next line** — progressive: from end select second line; further calls advance (`LineCursor.tla`). Buffer unchanged. Does **not** steal bare **next line** (move down) or **select last line**
- **select next N words** — keyboard ⇧⌥→ × N (N ≥ 2; caret-relative)
- **select last N words** / **highlight last N words** / **select previous N words** — select trailing N words from session buffer and arm type-over (N ≥ 2). Dual: `SelectLastWords.tla`
- **delete last N sentences** / **paragraphs** / **lines** — peel last N trailing units (N ≥ 2; Voice Control style)
- **delete next N sentences** / **paragraphs** / **lines** — remove next N units from session cursor (from end = starting at second; `MultiUnitEdit.tla`)
- **select last N sentences** / **previous N paragraphs** / **last N lines** — select trailing N units via ⇧← (N ≥ 2)
- **select next N sentences** / **paragraphs** / **lines** — select next N units from session cursor (from end = 2nd onward)
- **select all** — select all (⌘A)
- **unselect that** / **deselect** / **clear selection** — collapse selection to end (→)
- **bold that** / **make that bold** — select last phrase + bold (⌘B), then unselect
- **italic that** / **italicize that** — select last phrase + italic (⌘I), then unselect
- **underline that** — select last phrase + underline (⌘U), then unselect
- **cut that** / **cut it** — select last phrase + cut (⌘X); drop buffer delta
- **move left** / **previous word** — cursor left one word (⌥←)
- **move right** / **next word** — cursor right one word (⌥→)
- **move left N words** / **back N words** / **move previous N words** — cursor left N words (⌥← × N; keyboard only; buffer unchanged). Does **not** steal bare **move left**
- **move right N words** / **forward N words** / **move next N words** — cursor right N words (⌥→ × N). Does **not** steal bare **move right**
- **move left N characters** / **back N characters** — cursor left N characters (← × N)
- **move right N characters** / **forward N characters** — cursor right N characters (→ × N). Dual: `MoveN.tla`
- **move up** / **previous line** / **line up** / **up a line** / **go up** — cursor up one line (↑). Does **not** steal **select previous line**
- **move down** / **next line** / **line down** / **down a line** / **go down** — cursor down one line (↓)
- **go to start** / **beginning of line** — cursor to line start (⌘←)
- **go to end** / **end of line** — cursor to line end (⌘→)
- **beginning of document** / **top of document** / **start of document** / **go to top of document** / **go to beginning of document** — cursor to document start (⌘↑). Does **not** change line-edge **go to beginning** / **go to start**
- **end of document** / **bottom of document** / **go to end of document** / **go to bottom of document** — cursor to document end (⌘↓)
- **page up** / **scroll up** / **scroll page up** — Page Up key. Does **not** steal **move up**
- **page down** / **scroll down** / **scroll page down** — Page Down key. Does **not** steal **move down**
- **previous sentence** / **go to previous sentence** / **back a sentence** — progressive: from end → last sentence content start; further calls step back. Resets on content commit / clear / new session. Buffer unchanged (`MoveSentence.tla`, `SentenceCursor.tla`)
- **next sentence** / **go to next sentence** / **forward a sentence** / **move to next sentence** — progressive session cursor (`sentenceNavIndex`; nil = end): from end → second sentence content start (skip whitespace); further calls advance to 3rd, 4th, …. Single-sentence buffer is a no-op. Same content offset as **select next sentence**. Does **not** steal **select previous sentence**. Buffer unchanged (`MoveSentence.tla`, `SentenceCursor.tla`)
- Overlay badge shows sticky caps / spell mode when active
- When spell mode is on, caps transform is skipped and multi-segment joins glue without spaces
- **clear all** — wipe session transcript
- **press enter** / **press tab** / **press space** — key inserts
- Spoken **line break** → newline (same as **new line**)
- **press backspace** / **delete key** — Backspace once (keyboard only; buffer unchanged)
- **forward delete** / **press forward delete** / **delete forward** / **press delete forward** — Forward Delete once (0x75; keyboard only; buffer unchanged). Does **not** steal **press delete** / **delete key** (Backspace)
- **press escape** / **press esc** / **hit escape** / **escape key** — Escape once (keyboard only; buffer unchanged; does **not** cancel session). Bare **escape** is not a command
- **system undo** / **press undo** / **undo key** / **app undo** / **command undo** — system undo (⌘Z; keyboard only; buffer / edit stack unchanged). Does **not** steal **undo that** / **scratch that** / **correct that**
- **system redo** / **press redo** / **redo key** / **app redo** / **command redo** — system redo (⌘⇧Z; keyboard only; buffer / edit stack unchanged). Does **not** steal **redo that** (EditStack redo)
- **insert date** / **today's date** / **insert the date** — type today's date (e.g. `July 10, 2026`)
- **insert time** / **current time** / **insert the time** — type current local time (e.g. `3:45 p.m.`)
- **copy that** / **paste that** — clipboard
- **duplicate that** / **dupe that** / **copy paste that** — copy last phrase (or whole buffer) and append again
First segment auto-capitalizes. Consecutive duplicate segments skipped.
When sherpa provides token log-probs, `ConfidenceGate` rejects extreme
low-confidence dumps with length-aware thresholds (short hyps stricter;
`ConfidenceGate.tla`). When scores are nil (Parakeet),
`DecodeReject` still drops non-empty hyps on pure silence / low-energy
filler frames (`DecodeReject.tla`). Spoken `dot com` / `at sign`.
Custom vocab seeds cover common tech ASR confusions; edit in Settings → Audio. Speculative preview peeks every
~250ms while speaking, ~500ms when idle (`AdaptivePeek.tla`). Full command
list: Settings → Audio → Voice Commands.


## Components

```
 Microphone                                                        Target App
     │                                                                 ▲
     │ 48kHz stereo                                                    │ CGEvent
     ▼                                                                 │ keystrokes
┌──────────┐  16kHz mono   ┌─────────────┐  committed   ┌──────────┐  │
│  Audio   │──────────────►│ Transcriber │──segments───►│ AppState │──┘
│ Recorder │  AsyncStream  │   (actor)   │              │(MainActor│
└──────────┘               │             │◄──peek───────│  consumer│
 I/O thread                │  VAD + ASR  │  ~250/500ms  │  + peek) │
                           └─────────────┘              └──────────┘
                                                              │
                                                              ▼
                                                         Overlay UI
```

Three concurrency domains:
- **I/O thread** — AVAudioEngine tap, captures and resamples
- **Transcriber actor** — VAD + recognizer, serializes inference
- **MainActor** — session lifecycle, UI, text insertion


## Session Lifecycle

```
                       fn press            fn release
                ┌────────────────┐   ┌──────────────────┐
                │                ▼   │                   ▼
              ready ─────► recording ─────► transcribing ─────► ready
                ▲              │                 │         flush + linger
                │           ESC│              fn │press
                │              ▼                 ▼
                │           ready           recording       (rejoin)
                │         (cancel —           same session,
                └──────────no text)           text preserved
```

Hold-to-record. fn release stops audio capture but flush takes real
time, so **transcribing** covers that gap. During transcribing:

- **fn press** → rejoin (new stream + consumer; old stream is closed
  and can't accept data). Text accumulates.
- **ESC** → cancel. No flush; voids already-typed session text when incremental
  (`CancelDecision` / `deleteBackward`); overlay/session text discarded.

Recording runs two parallel tasks:
- **Consumer** — drains stream, feeds transcriber, types committed text
- **Peek** — polls transcriber ~250ms active / ~500ms idle (`DecodePolicy`)


## Audio Capture

AVAudioEngine tap on the I/O thread resamples to 16kHz mono and yields
~85ms chunks into an AsyncStream.

Engine is prepared at launch (no I/O — mic indicator off), started on
first recording (mic indicator on), and parked 0.5s after stop (so
quick rejoins reuse it). Device changes tear down and re-prepare.

**Shutdown order:** tap removed *before* stream finished, so in-flight
I/O callbacks can still yield. Reversed order loses ~85ms in a race.


## Transcriber

Two pieces of state receive every sample. They exist because
mid-recording commits need tight speech boundaries (VAD) while
end-of-recording flush needs complete audio (pendingAudio).

```
                  samples
                     │
            ┌────────┴────────┐
            ▼                 ▼
     ┌─────────────┐   ┌───────────┐
     │pendingAudio │   │ Silero VAD│
     │ (raw buffer)│   │ (endpoint)│
     └──────┬──────┘   └─────┬─────┘
            │           silence ≥ 0.5s
            │                 │
            │          commit signal
            │                 │
            └────────┬────────┘
                     ▼
              transcribe pending
           (peek / feedAudio / flush)
```

| | Audio source | When | Why |
|---|---|---|---|
| **feedAudio** | pendingAudio (all) | VAD silence end mid-recording | VAD only endpoints; raw buffer avoids onset lag |
| **peek** | pendingAudio (last 5s) | ~250ms active / ~500ms idle | show user everything since last commit |
| **flush** | pendingAudio (all) | recording ends | match what peek showed; same source as commit |

**pendingAudio** — all samples since last commit. Cleared on commit.
Shared source for peek, mid-recording commit, and flush — so preview,
incremental typing, and final text share one decode path.

**VAD** — Silero via sherpa-onnx; endpoint on user-tunable
`VadSettings.minSilenceDuration` (default 0.55s from
`DecodePolicy.vadMinSilenceDuration`, LiveKit-style) or
`vadMaxSpeechDuration` (15s). Settings → Audio → **Phrase Endpointing**
recreates VAD via `Transcriber.reconfigureVAD` (`VadEndpoint.tla` clamp dual).
Segment audio is *not* decoded; VAD is the endpointing signal only. Empty ASR
on a VAD endpoint keeps `pendingAudio` (false endpoint must not wipe speech).
Mid-clause VAD caps are downcased on join when the next segment starts with a
continuation verb (`SegmentJoiner`). Formal model: `specs/TranscriberBuffer.tla`
(TLC-checked).


### Peek Safeguards

The recognizer hallucinates from silence (e.g. "Yeah"). Guards:
- **VAD.Detected gate** — skip peek when no speech active
- **Min 4800 samples** (~0.3s) — too short = unreliable
- **Cap 5s** — bounds inference time on long utterances
- **Count cache** — skip ASR when `pendingAudio.count` is unchanged since the last peek (`DecodePolicy.shouldReusePeek` / `PeekCache.tla`); cleared on commit, flush, reset
- **Commit hyp reuse** — when speech-window fingerprint matches the last peek and pending fits the peek window, skip re-decode on VAD commit/flush (`DecodePolicy.shouldReuseCommitHyp` / `PeekCommitHyp.tla`)


## Concurrency Safety

Consumer and peek run concurrently, sessions start/stop at any time.

**`recordingSession`** — counter incremented per session, checked after
every `await`. Stale async work self-terminates on mismatch.

**`commitGen`** — counter incremented per committed segment. Peek
captures gen before inference, discards result if gen changed
(prevents stale preview from appearing after committed text).

**Actor isolation** — pendingAudio and VAD live on the Transcriber
actor. feedAudio and peek are serialized; no locks.

**Consumer survives stop** — fn release finishes the stream but does
not cancel the consumer. It must drain buffered audio, process
in-flight feedAudio results (VAD already popped those segments),
and flush. Only cancel and rejoin kill the consumer.
