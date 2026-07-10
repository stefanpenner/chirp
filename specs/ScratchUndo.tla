---- MODULE ScratchUndo ----
(*
  Spoken "scratch that" undoes the last committed/typed segment.

  Purpose: lastTypedCount tracks the previous delta; scratch removes
  that many characters from the transcript and (when incremental)
  deletes them from the target app.

  Mirrors DictationCommand + AppState.performScratchThat.
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* length of transcribedText
  lastTyped,     \* length of last delta (0 if none)
  typedToApp     \* characters sent to app (incremental mode)

vars == <<textLen, lastTyped, typedToApp>>

MaxLen == 10

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ lastTyped \in 0..MaxLen
  /\ typedToApp \in 0..MaxLen
  /\ lastTyped <= textLen
  /\ typedToApp <= textLen

Init ==
  /\ textLen = 0
  /\ lastTyped = 0
  /\ typedToApp = 0

----
\* Commit a segment of size n (1..remaining room)
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastTyped' = n
  /\ typedToApp' = typedToApp + n

\* Scratch that: undo last segment if any
Scratch ==
  /\ lastTyped > 0
  /\ textLen' = textLen - lastTyped
  /\ typedToApp' = typedToApp - lastTyped
  /\ lastTyped' = 0

\* Scratch with nothing to undo — no-op
ScratchEmpty ==
  /\ lastTyped = 0
  /\ UNCHANGED vars

\* New session clears all
Reset ==
  /\ textLen' = 0
  /\ lastTyped' = 0
  /\ typedToApp' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ Scratch
  \/ ScratchEmpty
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ typedToApp = textLen  \* incremental: app mirrors transcript
  /\ lastTyped <= textLen

StateConstraint == textLen <= MaxLen

====
