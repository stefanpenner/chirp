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
bazel test //:AudioCorpusPipelineTests --test_output=all
# or the broader suite (same harness + older integration cases):
bazel test //:TranscriberIntegrationTests --test_output=all
```

| Piece | Role |
|---|---|
| `SpeechAudioGenerator` | TTS (`say` + `afconvert`), noise, silence, WAV load |
| `TranscriptionScoring` | WER / majorWER / CER + ranked leaderboard |
| `AudioCorpusPipelineTests` | Generate → pipe → score → assert budgets |

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
Decode uses `withSpeechWindow` (lead+trail energy trim with 200ms rolls).
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
`three thirty pm`→`3:30 p.m.`, `three o'clock`→`3:00`), spoken cardinals
(`one hundred`→`100`, `twenty five`→`25`, `three point five`→`3.5`), ordinals
(`twenty first`→`21st`, `first of all` stays), dates (`march fifth twenty
twenty four`→`March 5, 2024`, `tomorrow`/`next monday` → absolute dates,
weekdays → `Monday`, bare `may I` stays), `50 percent`→`50%`, currency multi
(`20 dollars`→`$20`, `20 euros`→`€20`, `20 pounds`→`£20`, `20 yen`→`¥20`,
`50 cents`→`50¢`, `20 dollars and 50 cents`→`$20.50`).
Bare `one`/`two` stay words. Digit runs (≥3 single digits) concatenate for
phones (`five five five one two one two`→`555-1212`; 10-digit `XXX-XXX-XXXX`;
11-digit leading-1 `1-XXX-XXX-XXXX`; `oh`→`0`). Spoken email:
`john at example dot com`→`john@example.com`, multi-dot
`john at mail dot google dot com`→`john@mail.google.com` (requires `dot`; bare
`meet at noon` stays). Spoken symbols: `slash`→`/`, `asterisk`→`*`,
`underscore`→`_`, fractions `one half`→`½`. Lists: `bullet point` /
`next bullet` → `•`; `number one` / `next number` → `1.` / `2.`;
`end list` resets numbering. Session list counter resets each recording.
Relative dates use the local timezone. Settings → Audio → Auto-Formatting
toggles relative dates, numbered lists, and bullets. Spoken terminal punct
works mid-segment (`hello period next` → `hello. Next`) with content-word
guards.
Spoken `new line` / `new paragraph` rewrite in `TextPostProcessor`;
newlines type as Return keys via `TextInserter.steps`. Custom vocabulary: `DictationDictionary`
(built-in tech phrases + UserDefaults `chirp.dictationDictionary`).
Spoken edit commands (`DictationCommand` + `EditCommands.tla`):
- **scratch that** / **correct that** — multi-level undo (`EditStack`)
- **replace that** — next phrase replaces last (text stays until then; HUD “Replace…”)
- **redo that** — restore last scratched / word-deleted segment
- **delete last word** — drop trailing word (stack-aware; redo restores)
- **caps on / all caps on / no caps on** — sticky casing (`CapsMode`)
- **caps off** — back to normal casing
- **cap that / all caps that / no caps that** — transform last word
- **title case that** — title-case last phrase (stack delta)
- **sentence case that** — sentence-case last phrase
- **no space that** — join last word without leading space
- Overlay badge shows sticky caps mode when not normal
- **clear all** — wipe session transcript
- **press enter** / **press tab** — key inserts
- **copy that** / **paste that** — clipboard
First segment auto-capitalizes. Consecutive duplicate segments skipped.
When sherpa provides token log-probs, `ConfidenceGate` rejects extreme
low-confidence dumps (`ConfidenceGate.tla`). Spoken `dot com` / `at sign`.
Edit custom phrases in Settings → Audio. Speculative preview peeks every
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

**VAD** — emits segments on ≥0.5s silence (or 15s max). Segment audio is
*not* decoded; VAD is the endpointing signal only. Empty ASR on a VAD
endpoint keeps `pendingAudio` (false endpoint must not wipe speech).
Formal model: `specs/TranscriberBuffer.tla` (TLC-checked).


### Peek Safeguards

The recognizer hallucinates from silence (e.g. "Yeah"). Three guards:
- **VAD.Detected gate** — skip peek when no speech active
- **Min 4800 samples** (~0.3s) — too short = unreliable
- **Cap 5s** — bounds inference time on long utterances


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
