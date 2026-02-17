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

The core interaction is hold-to-record: fn press starts recording, fn
release stops it. Everything after fn release would ideally be instant,
but flush and transcription take real time. The **transcribing** state
exists to cover that gap — the user sees the overlay while remaining
audio is processed and typed. During that wind-down, the user can act:

- **fn press** → **rejoin** the session (keep accumulated text, start
  recording again). This creates a new audio stream and consumer because
  the previous stream was closed on fn release — once an AsyncStream is
  finished, it can't accept new data.
- **ESC** → **cancel** the session. No flush, no text typed, everything
  discarded.

**Recording** runs two parallel tasks:
- **Consumer** — drains audio from the stream, feeds the transcriber,
  commits segments as typed text
- **Peek** — polls the transcriber every 400ms for a speculative preview
  of uncommitted audio, so the user sees words before they're committed


## Audio Capture

AudioRecorder wraps AVAudioEngine. The tap callback runs on the engine's
real-time I/O thread, resamples 48kHz stereo to 16kHz mono, and yields
chunks (~1365 samples, ~85ms each) into an AsyncStream.

The engine is **prepared eagerly** (at app launch) but **started lazily**
(on first recording) to avoid showing the orange mic indicator at idle.
After recording stops, the engine is **parked after 0.5s** — stopped but
kept allocated so a quick rejoin reuses it without the startup cost. If
a device change occurs (headphones plugged in), the engine is torn down
and re-prepared from scratch because AVAudioEngine's input format may
have changed.

**Shutdown order matters:** stopRecording() removes the tap *before*
finishing the AsyncStream continuation. This way, any I/O callback
already in flight can still yield its buffer into the open stream.
Reversing this order creates a race where the callback's yield returns
`.terminated` and ~85ms of audio is lost.


## Transcriber

The transcriber actor holds two pieces of state that both receive every
audio sample. They exist because transcription has two competing needs:
mid-recording commits need tight speech boundaries (VAD's job), while
end-of-recording flush needs complete audio (pendingAudio's job).

```
                     samples
                        │
               ┌────────┴────────┐
               ▼                 ▼
        ┌──────────────┐   ┌────────────┐
        │ pendingAudio │   │ Silero VAD │
        │  (raw buffer)│   │            │
        └──────────────┘   └─────┬──────┘
               │                 │
               │           silence ≥ 0.5s
               │                 │
               │                 ▼
               │          ┌─────────────┐
               │          │ VAD segment │ (onset → offset audio)
               │          └─────┬───────┘
               │                │
     ┌─────────┴───┐    ┌───────┴─────┐
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

The recognizer will confidently produce text from silence or noise
(e.g. "Yeah", "Hm"). Three guards prevent this from reaching the user:

- **VAD.Detected gate** — only peek when the VAD thinks speech is
  happening. Without this, ambient noise produces hallucinated words.
- **Minimum 4800 samples (~0.3s)** — very short audio produces
  unreliable transcriptions. Wait for enough signal.
- **Cap to last 5s** — inference time scales with audio length. Without
  the cap, a long utterance makes peek lag behind real-time.


## Concurrency Safety

The consumer and peek tasks run concurrently and both call into the
transcriber actor, while sessions can start and stop at any time. Three
mechanisms prevent stale or cross-session work from corrupting state:

**Session counter** (`recordingSession`) — incremented on each new
session, checked after every `await`. If a session was cancelled or
replaced while the consumer was mid-`feedAudio`, the stale result is
discarded instead of typed into the wrong context.

**commitGen** — solves a narrower problem: peek runs every 400ms and
calls into the transcriber, but a committed segment may arrive while
peek is mid-inference. Without commitGen, the stale preview would
flash on screen after the committed text was already typed. Peek
captures the gen before calling the transcriber and discards the
result if it changed.

**Actor isolation** — pendingAudio and the VAD live inside the
Transcriber actor, so feedAudio and peekTranscription are serialized
automatically. No locks needed.

**Consumer not cancelled on stop** — when the user releases fn, the
stream is finished but the consumer task keeps running. It must:
drain any buffered audio still in the stream, process in-flight
feedAudio results (the VAD already popped those segments — dropping
them would lose text), then flush. Only cancelSession() and
rejoinSession() cancel the consumer.
