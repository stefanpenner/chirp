# Audio Pipeline

## Thread / Actor Map

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ I/O Thread (AVAudioEngine)                                                  │
│                                                                             │
│  installTap(bufferSize: 4096)                                               │
│       │                                                                     │
│       ▼                                                                     │
│  ┌──────────────────────┐                                                   │
│  │ tapBlock callback    │  fires every ~85ms (4096 samples @ 48kHz)         │
│  │                      │                                                   │
│  │  48kHz stereo buffer │                                                   │
│  │       │              │                                                   │
│  │       ▼              │                                                   │
│  │  AVAudioConverter    │                                                   │
│  │  48kHz → 16kHz mono  │                                                   │
│  │       │              │                                                   │
│  │       ▼              │                                                   │
│  │  onSamples([Float])  │─────────── continuation.yield(samples) ──────┐    │
│  │                      │                                              │    │
│  └──────────────────────┘                                              │    │
│                                                                        │    │
└────────────────────────────────────────────────────────────────────────│────┘
                                                                        │
                                                                        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ AsyncStream<[Float]> buffer                                                   │
│                                                                               │
│  [chunk₁] [chunk₂] [chunk₃] ...     ~1365 Float samples per chunk (85ms)     │
│                                                                               │
└────────────────────────────────────────────────────────────────────────│──────┘
                                                                        │
                                                                        │ for await
                                                                        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ @MainActor — audioConsumerTask                                                │
│                                                                               │
│  for await samples in stream {                                                │
│      ┌─────────────────────────────┐                                          │
│      │ compute RMS → audioLevel    │  (UI: volume meter)                      │
│      └─────────────┬───────────────┘                                          │
│                    │                                                          │
│                    ▼                                                          │
│      ┌─────────────────────────────────────────────────────────────┐          │
│      │ await transcriber.feedAudio(samples)  ──── hop to actor ───┼──┐       │
│      └─────────────────────────────────────────────────────────────┘  │       │
│                                                                      │       │
│                ┌─────────────────────────────────────────────────┐    │       │
│                │ returned segments (committed text)              │◄───┘       │
│                │                                                 │            │
│                │  for each segment:                               │            │
│                │    TextPostProcessor.process(raw)                │            │
│                │    commitGen += 1                                │            │
│                │    speculativeText = ""                          │            │
│                │    transcribedText += text   (UI: overlay)       │            │
│                │    textInserter.typeText()   (CGEvent keys)      │            │
│                └─────────────────────────────────────────────────┘            │
│  }                                                                            │
│                                                                               │
│  // --- stream ended (continuation.finish() was called) ---                   │
│                                                                               │
│  await transcriber.flush()  ─────────────────────── hop to actor ───┐        │
│                                                                      │        │
│  ◄───────────────────────────────────────────────────────────────────┘        │
│  remaining text → transcribedText, typeText()                                 │
│  sleep(lingerDuration)   // 800ms overlay linger                              │
│  status = .ready                                                              │
│  hideOverlay()                                                                │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘


┌───────────────────────────────────────────────────────────────────────────────┐
│ @MainActor — peekTask (parallel to consumer)                                  │
│                                                                               │
│  loop every 400ms:                                                            │
│    gen = commitGen                                                            │
│    preview = await transcriber.peekTranscription()                            │
│    guard commitGen == gen       // discard if commit happened mid-peek        │
│    speculativeText = preview    // (UI: overlay, italic)                      │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

## Transcriber Actor — Internal State

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ actor Transcriber                                                             │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐      │
│  │ pendingAudio: [Float]                                               │      │
│  │                                                                     │      │
│  │ Accumulates ALL samples from feedAudio() since last commit.         │      │
│  │ Cleared entirely when feedAudio() returns non-empty results.        │      │
│  │ Used by peekTranscription() as its audio source.                    │      │
│  │ NOT used by flush() — flush uses VAD segment audio instead.         │ ◄── MISMATCH
│  └─────────────────────────────────────────────────────────────────────┘      │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐      │
│  │ Silero VAD                                                          │      │
│  │                                                                     │      │
│  │  AcceptWaveform(samples)  ← receives same samples as pendingAudio   │      │
│  │       │                                                             │      │
│  │       ▼                                                             │      │
│  │  ┌──────────────────┐                                               │      │
│  │  │ Frame-level      │  512-sample windows (32ms)                    │      │
│  │  │ speech prob      │  threshold: 0.45                              │      │
│  │  │                  │                                               │      │
│  │  │ Detected() → 0/1 │  "is current frame speech?"                  │      │
│  │  └────────┬─────────┘                                               │      │
│  │           │                                                         │      │
│  │           ▼                                                         │      │
│  │  ┌──────────────────────────────────────┐                           │      │
│  │  │ Segment tracking                     │                           │      │
│  │  │                                      │                           │      │
│  │  │  speech onset ──► accumulate ──► silence detected                │      │
│  │  │       │              │              │                            │      │
│  │  │  (prob > 0.45    (recording)   (prob < 0.45                     │      │
│  │  │   for enough                    for ≥ 0.5s)                     │      │
│  │  │   frames)                           │                            │      │
│  │  │       │                             ▼                            │      │
│  │  │       │                    emit segment to queue                 │      │
│  │  │       │                    (contains audio from                  │      │
│  │  │       │                     onset to offset)                     │      │
│  │  │       │                                                          │      │
│  │  │  Constraints:                                                    │      │
│  │  │    min_speech_duration:  0.1s                                    │      │
│  │  │    min_silence_duration: 0.5s                                    │      │
│  │  │    max_speech_duration:  15s  (force-emit)                       │      │
│  │  └──────────────────────────────────────┘                           │      │
│  │           │                                                         │      │
│  │           ▼                                                         │      │
│  │  ┌──────────────────┐                                               │      │
│  │  │ Segment Queue    │  popped by feedAudio() and flush()            │      │
│  │  │ [seg₁, seg₂, …]  │  each seg has its own audio samples          │      │
│  │  └──────────────────┘                                               │      │
│  └─────────────────────────────────────────────────────────────────────┘      │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐      │
│  │ Offline Recognizer (Parakeet TDT 0.6b v2 int8)                      │      │
│  │                                                                     │      │
│  │  transcribeSamples([Float]) → String                                │      │
│  │                                                                     │      │
│  │  Called by:                                                          │      │
│  │    feedAudio  → with VAD segment audio (onset-to-offset)            │      │
│  │    peek       → with pendingAudio (all audio since last commit)     │      │
│  │    flush      → with VAD segment audio (onset-to-flush-point)       │      │
│  └─────────────────────────────────────────────────────────────────────┘      │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

## feedAudio() Flow

```
feedAudio(samples) {
    pendingAudio += samples                         ← append ALL
    VAD.AcceptWaveform(samples)                     ← feed to VAD

    while VAD has segments {
        segment = VAD.Front()                       ← VAD's own audio buffer
        text = transcribeSamples(segment.samples)   ← transcribe VAD audio
        results.append(text)
        VAD.Pop()
    }

    if results.nonEmpty {
        pendingAudio.removeAll()                    ← FULL CLEAR
    }                                               ← (not "remove up to segment boundary")

    return results
}
```

### pendingAudio vs VAD — what they contain after a commit

```
Timeline:   |-------- speech --------|-- silence --|--- new audio ---|
                                                    ▲
                                                    commit happens here
                                                    (VAD detected 0.5s silence)

After commit:
  pendingAudio = []                      ← wiped completely
  VAD internal  = has post-silence audio ← tracks continuously

Next feedAudio call adds new samples to both.

So after commit, pendingAudio RESTARTS from the next feedAudio call,
while VAD has continuous history including the inter-call gap.

Gap ≈ 1 buffer period ≈ 85ms
```


## stopRecording() → flush() Sequence

```
              Main Actor                          I/O Thread              Transcriber Actor
                 │                                    │                        │
 fn released ──► │                                    │                        │
                 │                                    │                        │
 stopRecording() │                                    │                        │
                 │                                    │                        │
   peekTask.cancel()                                  │                        │
                 │                                    │                        │
   continuation.finish() ─────────►  ╳                │                        │
                 │                    ╳ (yields after  │                        │
   recorder.stopRecording() ──────►  ╳  this point    │                        │
                 │                    ╳  are DROPPED)  │                        │
   status = .transcribing             │                │                        │
   speculativeText = ""               │                │                        │
                 │                    │                │                        │
                 │                    │                │                        │
   ─ ─ ─ ─ ─ ─  consumer task continues  ─ ─ ─ ─ ─ ─                         │
                 │                                                             │
   for-await drains remaining                                                  │
   buffered chunks                    │                                        │
                 │                                                             │
                 │  last feedAudio ────────────────────────────────────────────►│
                 │                                                             │
                 │◄────────────────────────────────── segments (if any) ────────│
                 │  type committed text                                        │
                 │                                                             │
   for-await loop exits (stream finished)                                      │
                 │                                                             │
                 │  flush() ──────────────────────────────────────────────────► │
                 │                                    VAD.Flush()              │
                 │                                    pop segments             │
                 │                                    transcribe segment audio │
                 │◄──────────────────────────────────────────── remaining text  │
                 │                                                             │
   type remaining text                                                         │
   sleep(800ms)  // linger                                                     │
   status = .ready                                                             │
   hideOverlay()                                                               │
```


## The "hey is it working" Bug — What Happens

```
User says: "hey is it working"
                    then releases fn

Timeline:
─────────────────────────────────────────────────────────────────────►
 "hey"            "is"   "it"   "working"    fn-release
   │               │      │        │             │
   ▼               ▼      ▼        ▼             ▼

  VAD: speech onset detected ───────────────────►│
                                                  │
  peek (every 400ms):                             │
    pendingAudio has all speech                   │
    transcribes → "hey is it working"             │
    shown as speculativeText on overlay           │
                                                  │
                                            stopRecording()
                                                  │
                                            continuation.finish()
                                            removeTap()

  Consumer for-await drains remaining chunks:
    feedAudio(last-chunks)
       VAD detects 0.5s silence? ─── maybe ──► commits "hey is it working"
                                                │
                                                ▼
                                          pendingAudio.removeAll()
                                          transcribedText += "hey is it working"
                                          typeText("hey is it working")

  for-await exits

  flush():
    VAD.Flush()
    VAD emits segment? ─── from what audio?
       │
       ├── If silence triggered commit above:
       │     remaining audio = post-commit noise/silence
       │     VAD may detect speech from noise (fn click, ambient)
       │     segment audio → transcribeSamples → "Yeah" ← HALLUCINATION
       │     typed: "hey is it working Yeah"
       │
       └── If speech was NOT committed (no 0.5s silence):
             VAD flushes active speech segment
             segment audio = onset-to-flush-point
             BUT: VAD onset may lag behind actual speech start
             segment is SHORTER than what peek saw
             segment audio ≈ "is it working" (missing "hey")
             transcribeSamples("is it working") → ???
             or if segment very short → "Yeah"


RESULT: Either trailing hallucination or truncated/wrong transcription
```

## peek vs feedAudio vs flush — Audio Source Comparison

```
                    pendingAudio                 VAD segment audio
                    ─────────────                ─────────────────
feedAudio commit:   (not used for transcription) ✓ onset-to-offset
peek:               ✓ all since last commit      (not used)
flush:              (not used)                   ✓ onset-to-flush-point

                    ▲                            ▲
                    │                            │
               FULL recording                TRIMMED to speech
               since last commit             boundaries (onset lag)

The mismatch: peek uses pendingAudio and produces correct text.
flush uses VAD segment audio which may be shorter (onset lag)
or may transcribe post-commit noise (hallucination).
```

## Race Window in stopRecording()

```
stopRecording() currently:

    continuation.finish()          ← I/O thread yields after this = DROPPED
    audioRecorder.stopRecording()  ← removeTap

    ┌──────────────────────────────────────────┐
    │ RACE: I/O thread may be mid-callback     │
    │ between finish() and removeTap().        │
    │ Its yield() returns .terminated.         │
    │ That buffer's audio is lost.             │
    │                                          │
    │ Window ≈ nanoseconds (both on main),     │
    │ but I/O callback runs concurrently.      │
    │ Worst case: 1 buffer lost (85ms).        │
    └──────────────────────────────────────────┘

Swapped order (stop recorder first):

    audioRecorder.stopRecording()  ← removeTap — no new callbacks start
    continuation.finish()          ← in-flight callback can still yield

    Any callback already running on I/O thread completes
    and successfully yields to the still-open continuation.
```
