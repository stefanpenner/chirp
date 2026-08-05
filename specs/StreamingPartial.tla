---- MODULE StreamingPartial ----
(*
  Peek-only vs true streaming / EOU partials (SOTA gap yodel-88e).

  Product today: **peekOnly** — offline Parakeet re-decodes pendingAudio on a
  cadence (AdaptivePeek + PeekCache + PeekCommit). Speculative text is NOT a
  streaming ASR partial; VAD endpoints + flush commit.

  Future optional: **streamingEOU** — cache-aware / EOU model emits partials
  and end-of-utterance without a separate offline re-decode. Not shipped;
  modeled so we prove mode isolation and commit safety before any trial.

  Reduce:
    - enum mode (not string product IDs)
    - bools: partial, committed, speech, eou (not token counts)
    - MaxTick lid on abstract time
  Dual: StreamingPartialDecision.swift
*)

EXTENDS Integers, TLC

VARIABLES
  mode,        \* "peekOnly" | "streamingEOU"
  phase,       \* "ready" | "recording" | "transcribing"
  speech,      \* mic speech active (VAD detected / stream speech)
  partial,     \* speculative / streaming partial non-empty
  committed,   \* session committed text non-empty
  eou,         \* end-of-utterance signal (streaming mode only meaningful)
  tick         \* lid: abstract steps

MaxTick == 4

ModeSet == {"peekOnly", "streamingEOU"}
PhaseSet == {"ready", "recording", "transcribing"}

vars == <<mode, phase, speech, partial, committed, eou, tick>>

TypeOK ==
  /\ mode \in ModeSet
  /\ phase \in PhaseSet
  /\ speech \in BOOLEAN
  /\ partial \in BOOLEAN
  /\ committed \in BOOLEAN
  /\ eou \in BOOLEAN
  /\ tick \in 0..MaxTick

\* Product default: peek-only offline path
Init ==
  /\ mode = "peekOnly"
  /\ phase = "ready"
  /\ speech = FALSE
  /\ partial = FALSE
  /\ committed = FALSE
  /\ eou = FALSE
  /\ tick = 0

----
\* Mode select only when idle (orthogonal EngineMode/PipelineRebuild detail)
SelectMode(m) ==
  /\ phase = "ready"
  /\ m \in ModeSet
  /\ mode' = m
  /\ partial' = FALSE
  /\ eou' = FALSE
  /\ UNCHANGED <<phase, speech, committed, tick>>

StartRecording ==
  /\ phase = "ready"
  /\ tick < MaxTick
  /\ phase' = "recording"
  /\ speech' = FALSE
  /\ partial' = FALSE
  /\ eou' = FALSE
  /\ tick' = tick + 1
  /\ UNCHANGED <<mode, committed>>

\* Speech on/off (VAD or stream)
SpeechOn ==
  /\ phase = "recording"
  /\ speech' = TRUE
  /\ eou' = FALSE
  /\ UNCHANGED <<mode, phase, partial, committed, tick>>

SpeechOff ==
  /\ phase = "recording"
  /\ speech = TRUE
  /\ speech' = FALSE
  /\ UNCHANGED <<mode, phase, partial, committed, eou, tick>>

\* Peek-only: offline re-decode of pending → speculative partial
PeekPartial ==
  /\ mode = "peekOnly"
  /\ phase = "recording"
  /\ speech = TRUE
  /\ tick < MaxTick
  /\ partial' = TRUE
  /\ tick' = tick + 1
  /\ UNCHANGED <<mode, phase, speech, committed, eou>>

\* Streaming: model emits growing partial without offline re-decode
StreamPartial ==
  /\ mode = "streamingEOU"
  /\ phase = "recording"
  /\ speech = TRUE
  /\ tick < MaxTick
  /\ partial' = TRUE
  /\ eou' = FALSE
  /\ tick' = tick + 1
  /\ UNCHANGED <<mode, phase, speech, committed>>

\* Streaming EOU fires (end of utterance) — may auto-commit
StreamEOU ==
  /\ mode = "streamingEOU"
  /\ phase = "recording"
  /\ speech = TRUE
  /\ eou' = TRUE
  /\ speech' = FALSE
  /\ UNCHANGED <<mode, phase, partial, committed, tick>>

\* Auto-commit on EOU only in streaming mode with partial
EOUCommit ==
  /\ mode = "streamingEOU"
  /\ phase = "recording"
  /\ eou = TRUE
  /\ partial = TRUE
  /\ committed' = TRUE
  /\ partial' = FALSE
  /\ eou' = FALSE
  /\ UNCHANGED <<mode, phase, speech, tick>>

\* Peek-only / shared: VAD silence endpoint mid-session → commit partial
VadCommit ==
  /\ phase = "recording"
  /\ partial = TRUE
  /\ ~speech
  /\ committed' = TRUE
  /\ partial' = FALSE
  /\ eou' = FALSE
  /\ UNCHANGED <<mode, phase, speech, tick>>

\* User releases hotkey → transcribing (drain)
StopRecording ==
  /\ phase = "recording"
  /\ phase' = "transcribing"
  /\ speech' = FALSE
  /\ eou' = FALSE
  /\ UNCHANGED <<mode, partial, committed, tick>>

\* Flush: promote partial into committed if still non-empty (empty-total dual)
FlushPromote ==
  /\ phase = "transcribing"
  /\ partial = TRUE
  /\ committed' = TRUE
  /\ partial' = FALSE
  /\ UNCHANGED <<mode, phase, speech, eou, tick>>

\* Flush with nothing left
FlushEmpty ==
  /\ phase = "transcribing"
  /\ partial = FALSE
  /\ UNCHANGED <<mode, phase, speech, partial, committed, eou, tick>>

Finish ==
  /\ phase = "transcribing"
  /\ phase' = "ready"
  /\ partial' = FALSE
  /\ eou' = FALSE
  /\ speech' = FALSE
  /\ UNCHANGED <<mode, committed, tick>>

Cancel ==
  /\ phase \in {"recording", "transcribing"}
  /\ phase' = "ready"
  /\ speech' = FALSE
  /\ partial' = FALSE
  /\ committed' = FALSE
  /\ eou' = FALSE
  /\ UNCHANGED <<mode, tick>>

Next ==
  \/ \E m \in ModeSet: SelectMode(m)
  \/ StartRecording
  \/ SpeechOn
  \/ SpeechOff
  \/ PeekPartial
  \/ StreamPartial
  \/ StreamEOU
  \/ EOUCommit
  \/ VadCommit
  \/ StopRecording
  \/ FlushPromote
  \/ FlushEmpty
  \/ Finish
  \/ Cancel

Spec == Init /\ [][Next]_vars

----
\* Safety

\* Speculative partial only while in a session (recording or drain)
PartialOnlyInSession ==
  partial => phase \in {"recording", "transcribing"}

\* EOU flag only meaningful / set in streaming mode
EOUOnlyStreaming ==
  eou => mode = "streamingEOU"

\* Peek-only never auto-commits via EOU (no EOUCommit without streaming)
\* Structural: EOUCommit requires mode=streamingEOU.
\* Observational: peekOnly + eou is impossible
PeekOnlyNoEOU ==
  mode = "peekOnly" => ~eou

\* Ready is clean of in-flight speech/partial/eou
ReadyClean ==
  phase = "ready" => (/\ ~speech /\ ~partial /\ ~eou)

\* Streaming EOU cannot emit partials while not speaking
\* (StreamPartial requires speech; PeekPartial requires speech)
\* Partial may linger after SpeechOff until VadCommit/Flush — allowed.

StateConstraint ==
  tick <= MaxTick

Inv ==
  /\ TypeOK
  /\ PartialOnlyInSession
  /\ EOUOnlyStreaming
  /\ PeekOnlyNoEOU
  /\ ReadyClean

\* Bait: partial outside session must FAIL under TLC
BaitInv == ~PartialOnlyInSession

====
