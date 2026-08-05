---- MODULE SessionMachine ----
(*
  Chirp hold-to-talk session state machine.

  Purpose: prove safety of ready / recording / transcribing lifecycle
  under rejoin, cancel, and natural flush+linger completion.

  Models AppState transitions from ChirpApp.swift:
    startRecording, rejoinSession, stopRecording, cancelSession, finishSession

  Consumer generation (yodel-adv4):
    rejoin keeps recordingSession (text preserved) but bumps consumerGen so
    a cooperatively-cancelled old consumer cannot CommitText after the new
    consumer starts. staleAlive models the dual-consumer window until OldDie.

  NOT modeled (orthogonal): download/load, overlay UI, peek gen counters,
  pipeline rebuild, audio I/O details.
*)

EXTENDS Integers, TLC

VARIABLES
  status,          \* "ready" | "recording" | "transcribing"
  session,         \* recordingSession counter
  textNonEmpty,    \* whether transcribedText has content
  peeking,         \* peek task active
  consumerAlive,   \* active (current-gen) audio consumer task
  consumerGen,     \* generation of the active consumer (lid: 0..MaxGen)
  staleAlive       \* old consumer still finishing after rejoin cancel

\* TLC lid — product uses unbounded UInt64; tiny domain for model check
MaxGen == 3

vars == <<status, session, textNonEmpty, peeking, consumerAlive,
          consumerGen, staleAlive>>

TypeOK ==
  /\ status \in {"ready", "recording", "transcribing"}
  /\ session \in Nat
  /\ textNonEmpty \in BOOLEAN
  /\ peeking \in BOOLEAN
  /\ consumerAlive \in BOOLEAN
  /\ consumerGen \in Nat
  /\ staleAlive \in BOOLEAN

Init ==
  /\ status = "ready"
  /\ session = 0
  /\ textNonEmpty = FALSE
  /\ peeking = FALSE
  /\ consumerAlive = FALSE
  /\ consumerGen = 0
  /\ staleAlive = FALSE

----
\* Actions (guards match ChirpApp)

\* ready → recording (new session, clear text, fresh consumer gen)
StartRecording ==
  /\ status = "ready"
  /\ status' = "recording"
  /\ session' = session + 1
  /\ textNonEmpty' = FALSE
  /\ peeking' = TRUE
  /\ consumerAlive' = TRUE
  /\ consumerGen' = consumerGen + 1
  /\ staleAlive' = FALSE

\* recording → transcribing (stop hotkey; consumer drains then flushes)
StopRecording ==
  /\ status = "recording"
  /\ status' = "transcribing"
  /\ peeking' = FALSE
  /\ UNCHANGED <<session, textNonEmpty, consumerAlive, consumerGen, staleAlive>>

\* transcribing → recording (rejoin: same session, keep text, bump consumer gen)
\* If a consumer was still alive, it becomes stale until OldDie.
Rejoin ==
  /\ status = "transcribing"
  /\ status' = "recording"
  /\ peeking' = TRUE
  /\ consumerAlive' = TRUE
  /\ consumerGen' = consumerGen + 1
  /\ staleAlive' = (consumerAlive \/ staleAlive)
  /\ UNCHANGED <<session, textNonEmpty>>

\* Stale (cancelled) consumer finishes — no commit allowed from it
OldDie ==
  /\ staleAlive
  /\ staleAlive' = FALSE
  /\ UNCHANGED <<status, session, textNonEmpty, peeking, consumerAlive, consumerGen>>

\* recording | transcribing → ready (ESC cancel; bump session + gen; drop text)
Cancel ==
  /\ status \in {"recording", "transcribing"}
  /\ status' = "ready"
  /\ session' = session + 1
  /\ textNonEmpty' = FALSE
  /\ peeking' = FALSE
  /\ consumerAlive' = FALSE
  /\ consumerGen' = consumerGen + 1
  /\ staleAlive' = FALSE

\* transcribing → ready (active consumer finished flush + linger)
\* Only when active consumer still alive for this session path.
FinishSession ==
  /\ status = "transcribing"
  /\ consumerAlive = TRUE
  /\ ~staleAlive          \* wait for dual window to close (or OldDie first)
  /\ status' = "ready"
  /\ consumerAlive' = FALSE
  /\ peeking' = FALSE
  /\ UNCHANGED <<session, textNonEmpty, consumerGen, staleAlive>>

\* Commit text only from the *active* consumer (not stale)
CommitText ==
  /\ status \in {"recording", "transcribing"}
  /\ consumerAlive = TRUE
  /\ textNonEmpty' = TRUE
  /\ UNCHANGED <<status, session, peeking, consumerAlive, consumerGen, staleAlive>>

Next ==
  \/ StartRecording
  \/ StopRecording
  \/ Rejoin
  \/ OldDie
  \/ Cancel
  \/ FinishSession
  \/ CommitText

Spec == Init /\ [][Next]_vars

----
\* Safety properties

\* Never peek while not recording
PeekOnlyWhileRecording ==
  peeking => status = "recording"

\* Active consumer must be alive whenever we are recording
ConsumerAliveWhileRecording ==
  status = "recording" => consumerAlive

\* Ready is a clean idle: no peek, no active or stale consumer
ReadyIsIdle ==
  status = "ready" => (/\ ~peeking /\ ~consumerAlive /\ ~staleAlive)

\* Dual-consumer window only while recording after rejoin (not ready)
StaleOnlyWithActiveOrTranscribing ==
  staleAlive => status \in {"recording", "transcribing"}

\* Bound for finite model checking (referenced from .cfg)
\* Lid: product consumerGen is UInt64; TLC keeps domain tiny.
StateConstraint ==
  /\ session < 5
  /\ consumerGen <= MaxGen

\* Invariant bundle
Inv ==
  /\ TypeOK
  /\ PeekOnlyWhileRecording
  /\ ConsumerAliveWhileRecording
  /\ ReadyIsIdle
  /\ StaleOnlyWithActiveOrTranscribing

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ReadyIsIdle

====
