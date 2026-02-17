# Audio Pipeline

Chirp turns speech into keystrokes: hold a hotkey, talk, release, and
your words appear in whatever app has focus. Audio is captured from the
microphone, streamed through a VAD to detect speech boundaries, and
transcribed by an offline recognizer (Parakeet TDT). Committed text is
typed into the target app via synthetic keyboard events. A speculative
preview runs in parallel so the user sees their words on an overlay
before the final transcription is committed.

## Overview

```
 Microphone                                                           Target App
     │                                                                    ▲
     │ 48kHz stereo                                                       │ CGEvent
     ▼                                                                    │ keystrokes
┌──────────┐  16kHz mono   ┌─────────────┐  committed    ┌─────────────┐  │
│  Audio   │──────────────►│ Transcriber │──segments────►│  AppState   │──┘
│ Recorder │  AsyncStream  │   (actor)   │               │ (MainActor) │
└──────────┘               │             │◄──peek────────│             │
 I/O thread                │  VAD + ASR  │  every 400ms  │  consumer   │
                           └─────────────┘               │  + peek     │
                                                         └─────────────┘
                                                               │
                                                               ▼
                                                          Overlay UI
```

Three concurrency domains:
- **I/O thread** — AVAudioEngine tap callback, captures and resamples audio
- **Transcriber actor** — owns VAD and recognizer, serializes all inference
- **MainActor** — AppState drives the session, updates UI, types text


## Session Lifecycle

```
                         fn press             fn release
                 ┌─────────────────┐    ┌──────────────────┐
                 │                 ▼    │                   ▼
               ready ──────► recording ──────► transcribing ──────► ready
                 ▲               │                  │          flush + linger
                 │            ESC│               fn │press
                 │               ▼                  ▼
                 │            ready            recording        (rejoin)
                 │          (cancel —            same session,
                 │           no flush,           text preserved
                 └───────────no text)
```

A **session** begins on fn press from ready, and ends either naturally
(linger timeout after flush) or by cancellation (ESC).

**Recording** runs two parallel tasks:
- **Consumer** — drains audio from the stream, feeds the transcriber,
  commits segments as typed text
- **Peek** — polls the transcriber every 400ms for a speculative preview
  of uncommitted audio (shown italic in the overlay)

**Transcribing** is the wind-down phase after fn release. The consumer
drains any buffered audio, flushes the transcriber, types remaining text,
lingers 800ms for the user to read the overlay, then hides it.

**Rejoin** — if fn is pressed again during transcribing, the old consumer
is cancelled (interrupting flush/linger) and a fresh recording cycle starts
within the same session. Previously committed text is preserved.

**Cancel** — ESC kills everything immediately. No flush, no text typed,
all accumulated text discarded.


## Audio Capture

AudioRecorder wraps AVAudioEngine. The tap callback runs on the engine's
real-time I/O thread, resamples 48kHz stereo to 16kHz mono, and yields
chunks (~1365 samples, ~85ms each) into an AsyncStream.

```
┌────────────────────────────────────────────────────┐
│ Engine lifecycle                                   │
│                                                    │
│  prepare() ─► engine allocated, no I/O             │
│               mic indicator OFF                    │
│                                                    │
│  startRecording() ─► start engine + install tap    │
│                      mic indicator ON              │
│                                                    │
│  stopRecording() ─► remove tap + schedule park     │
│                     park after 0.5s ─► engine stop  │
│                     mic indicator OFF              │
│                                                    │
│  rejoin within 0.5s ─► cancel park, reuse engine   │
│                                                    │
│  device change ─► teardown + prepare from scratch  │
└────────────────────────────────────────────────────┘
```

**Shutdown order matters:** stopRecording() removes the tap *before*
finishing the continuation, so any in-flight I/O callback can still
yield into the open stream. Reversing this order would lose ~85ms of
audio in a race window.


## Transcriber

The transcriber actor holds two pieces of state that receive the same
audio but serve different purposes:

```
                     samples
                        │
               ┌────────┴────────┐
               ▼                 ▼
        ┌─────────────┐   ┌───────────┐
        │ pendingAudio │   │ Silero VAD │
        │  (raw buffer)│   │            │
        └──────────────┘   └─────┬──────┘
               │                 │
               │           silence ≥ 0.5s
               │                 │
               │                 ▼
               │          ┌────────────┐
               │          │ VAD segment │ (onset → offset audio)
               │          └─────┬──────┘
               │                │
     ┌─────────┴───┐    ┌──────┴──────┐
     │ peek, flush │    │  feedAudio  │
     │ transcribe  │    │  transcribe │
     │ pendingAudio│    │ VAD segment │
     └─────────────┘    └─────────────┘
```

**Two transcription paths, one recognizer:**

| | Audio source | When | Why this source |
|---|---|---|---|
| **feedAudio** | VAD segment | 0.5s silence detected mid-recording | Tight speech boundaries, no silence waste |
| **peek** | pendingAudio (last 5s) | Every 400ms during recording | Shows the user everything since last commit |
| **flush** | pendingAudio (all) | Recording ends | Matches what peek showed — no onset-lag clipping |

**pendingAudio** accumulates every sample since the last commit. When
feedAudio commits a segment, pendingAudio is cleared entirely. peek and
flush both read from it, so the speculative preview and the final
transcription use the same audio source.

**VAD** tracks speech/silence continuously and emits segments to a queue
when it detects ≥0.5s of silence (or speech hits 15s max). feedAudio
pops these segments and transcribes the VAD's own audio buffer. flush
also pops the queue but *discards* the segment audio, transcribing
pendingAudio instead.

**Why the split?** VAD onset detection lags behind actual speech start,
so its segments can be clipped at the beginning. For mid-recording
commits this is acceptable (the next utterance starts fresh). But at
flush time, clipping would lose the start of the user's final words.
Using pendingAudio for flush avoids this.


### Peek Safeguards

Peek only runs inference when:
- VAD detects active speech (avoids hallucinating words from silence)
- pendingAudio has ≥ 4800 samples (~0.3s, enough for meaningful recognition)
- Capped to the last 5s to bound inference time on long utterances

If a committed segment arrives while peek is mid-inference, the result
is discarded (commitGen mismatch). This prevents stale speculative text
from appearing after committed text has already been typed.


## Concurrency Safety

**Session counter** (`recordingSession`) — incremented on each new
session, checked after every `await`. Any async work from a previous
session discovers the mismatch and exits. Uses wrapping arithmetic
to handle overflow.

**commitGen** — incremented on each committed segment. Peek captures
the current gen before calling into the transcriber. If a commit
happened during the peek, the gen won't match and the preview is
dropped.

**Actor isolation** — pendingAudio and the VAD are only accessed
through the Transcriber actor. feedAudio and peekTranscription never
run concurrently.

**Consumer not cancelled on stop** — stopRecording() finishes the
stream but does *not* cancel the consumer task. The consumer must
process any in-flight feedAudio results (the VAD already popped them)
and then flush. Cancellation only happens via cancelSession() or
rejoinSession().
