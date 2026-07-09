---- MODULE SessionMachine ----
(*
  Chirp hold-to-talk session state machine.

  Purpose: prove safety of ready / recording / transcribing lifecycle
  under rejoin, cancel, and natural flush+linger completion.

  Models AppState transitions from ChirpApp.swift:
    startRecording, rejoinSession, stopRecording, cancelSession, finishSession

  NOT modeled (orthogonal): download/load, overlay UI, peek gen counters,
  pipeline rebuild, audio I/O details.
*)

EXTENDS Integers, TLC

VARIABLES
  status,          \* "ready" | "recording" | "transcribing"
  session,         \* recordingSession counter
  textNonEmpty,    \* whether transcribedText has content
  peeking,         \* peek task active
  consumerAlive    \* audio consumer task active

vars == <<status, session, textNonEmpty, peeking, consumerAlive>>

TypeOK ==
  /\ status \in {"ready", "recording", "transcribing"}
  /\ session \in Nat
  /\ textNonEmpty \in BOOLEAN
  /\ peeking \in BOOLEAN
  /\ consumerAlive \in BOOLEAN

Init ==
  /\ status = "ready"
  /\ session = 0
  /\ textNonEmpty = FALSE
  /\ peeking = FALSE
  /\ consumerAlive = FALSE

----
\* Actions (guards match ChirpApp)

\* ready → recording (new session, clear text)
StartRecording ==
  /\ status = "ready"
  /\ status' = "recording"
  /\ session' = session + 1
  /\ textNonEmpty' = FALSE
  /\ peeking' = TRUE
  /\ consumerAlive' = TRUE

\* recording → transcribing (stop hotkey; consumer drains then flushes)
StopRecording ==
  /\ status = "recording"
  /\ status' = "transcribing"
  /\ peeking' = FALSE
  /\ UNCHANGED <<session, textNonEmpty, consumerAlive>>

\* transcribing → recording (rejoin: same session, keep text)
Rejoin ==
  /\ status = "transcribing"
  /\ status' = "recording"
  /\ peeking' = TRUE
  /\ consumerAlive' = TRUE
  /\ UNCHANGED <<session, textNonEmpty>>

\* recording | transcribing → ready (ESC cancel; bump session; drop text)
Cancel ==
  /\ status \in {"recording", "transcribing"}
  /\ status' = "ready"
  /\ session' = session + 1
  /\ textNonEmpty' = FALSE
  /\ peeking' = FALSE
  /\ consumerAlive' = FALSE

\* transcribing → ready (consumer finished flush + linger)
\* Only when consumer still alive for this session path.
FinishSession ==
  /\ status = "transcribing"
  /\ consumerAlive = TRUE
  /\ status' = "ready"
  /\ consumerAlive' = FALSE
  /\ peeking' = FALSE
  /\ UNCHANGED <<session, textNonEmpty>>

\* Commit text while recording (VAD segment) or after flush in transcribing
CommitText ==
  /\ status \in {"recording", "transcribing"}
  /\ consumerAlive = TRUE
  /\ textNonEmpty' = TRUE
  /\ UNCHANGED <<status, session, peeking, consumerAlive>>

Next ==
  \/ StartRecording
  \/ StopRecording
  \/ Rejoin
  \/ Cancel
  \/ FinishSession
  \/ CommitText

Spec == Init /\ [][Next]_vars

----
\* Safety properties

\* Never peek while not recording
PeekOnlyWhileRecording ==
  peeking => status = "recording"

\* Consumer must be alive whenever we are recording
ConsumerAliveWhileRecording ==
  status = "recording" => consumerAlive

\* Ready is a clean idle: no peek, no consumer
ReadyIsIdle ==
  status = "ready" => (/\ ~peeking /\ ~consumerAlive)

\* Bound for finite model checking (referenced from .cfg)
StateConstraint == session < 5

\* Invariant bundle
Inv ==
  /\ TypeOK
  /\ PeekOnlyWhileRecording
  /\ ConsumerAliveWhileRecording
  /\ ReadyIsIdle

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ReadyIsIdle

====
