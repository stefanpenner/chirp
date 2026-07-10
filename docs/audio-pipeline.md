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

Scoring helpers live in `Tests/ChirpTests/TranscriptionScoring.swift`
(always-on unit tests via `//:TextTests`). Generation is
`SpeechAudioGenerator` (`say` + `afconvert`). Budgets: mean majorWER ≤ 8%,
mean raw WER ≤ 12%, median ≤ 5% on clean TTS; silence must not hallucinate.
Decode uses `withSpeechWindow` (lead+trail energy trim with 200ms rolls).


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
 I/O thread                │  VAD + ASR  │  every 400ms │  + peek) │
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
- **ESC** → cancel. No flush, no typing, text discarded.

Recording runs two parallel tasks:
- **Consumer** — drains stream, feeds transcriber, types committed text
- **Peek** — polls transcriber every 400ms for speculative preview


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
| **peek** | pendingAudio (last 5s) | every 400ms | show user everything since last commit |
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
