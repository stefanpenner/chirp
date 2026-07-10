---- MODULE CancelVoid ----
(*
  ESC cancel voids already-typed dictation text when incremental.

  Purpose: prove that cancel clears session text and that the app
  delete count matches CancelDecision.appCharsToDelete.

  Dual of CancelDecision + AppState.cancelSession void path.
*)

EXTENDS Integers, TLC

VARIABLES
  phase,       \* "ready" | "recording" | "transcribing"
  typedLen,    \* length of session transcript
  typesInc,    \* TRUE when pipeline types incrementally mid-session
  lastDelete   \* deleteCount from most recent Cancel (0 until first cancel)

vars == <<phase, typedLen, typesInc, lastDelete>>

MaxLen == 3

\* Pure gate dual of CancelDecision.appCharsToDelete
DeleteCount(len, inc) ==
  IF inc THEN len ELSE 0

TypeOK ==
  /\ phase \in {"ready", "recording", "transcribing"}
  /\ typedLen \in 0..MaxLen
  /\ typesInc \in BOOLEAN
  /\ lastDelete \in 0..MaxLen

Init ==
  /\ phase = "ready"
  /\ typedLen = 0
  /\ typesInc \in BOOLEAN
  /\ lastDelete = 0

----
\* ready → recording (new session, clear text)
StartRecording ==
  /\ phase = "ready"
  /\ phase' = "recording"
  /\ typedLen' = 0
  /\ UNCHANGED <<typesInc, lastDelete>>

\* Commit mid-session text while recording
Commit(n) ==
  /\ phase = "recording"
  /\ n \in 1..MaxLen
  /\ typedLen + n <= MaxLen
  /\ typedLen' = typedLen + n
  /\ UNCHANGED <<phase, typesInc, lastDelete>>

\* recording → transcribing
StopRecording ==
  /\ phase = "recording"
  /\ phase' = "transcribing"
  /\ UNCHANGED <<typedLen, typesInc, lastDelete>>

\* recording | transcribing → ready; void typedLen; record deleteCount
Cancel ==
  /\ phase \in {"recording", "transcribing"}
  /\ lastDelete' = DeleteCount(typedLen, typesInc)
  /\ typedLen' = 0
  /\ phase' = "ready"
  /\ UNCHANGED typesInc

Next ==
  \/ StartRecording
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ StopRecording
  \/ Cancel

Spec == Init /\ [][Next]_vars

----
\* After Cancel (and Init), ready has no session text
ReadyIsVoided ==
  phase = "ready" => typedLen = 0

\* Batch mode never deletes from the app
BatchNeverDeletes ==
  ~typesInc => lastDelete = 0

\* lastDelete is a valid delete count for some prior typedLen under typesInc
DeleteCountBounded ==
  lastDelete <= MaxLen

Inv ==
  /\ TypeOK
  /\ ReadyIsVoided
  /\ BatchNeverDeletes
  /\ DeleteCountBounded

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ReadyIsVoided

StateConstraint == typedLen <= MaxLen

====
