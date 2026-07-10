---- MODULE DuplicateCommand ----
(*
  Spoken "duplicate that": copy last phrase, append again.

  Dual: DictationCommand.duplicateThat + AppState.performDuplicateThat
  (prefers EditStack.lastDelta; clipboard gets that text; buffer grows by it).

  Grain: abstract lengths only. MaxLen 3 keeps TLC tiny.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  clipboardLen,   \* system clipboard length
  lastDeltaLen,   \* length of last stack delta (phrase)
  lastOp          \* "none" | "commit" | "duplicate"

vars == <<bufferLen, clipboardLen, lastDeltaLen, lastOp>>

MaxLen == 3

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ clipboardLen \in 0..MaxLen
  /\ lastDeltaLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "duplicate"}
  /\ lastDeltaLen <= bufferLen

Init ==
  /\ bufferLen = 0
  /\ clipboardLen = 0
  /\ lastDeltaLen = 0
  /\ lastOp = "none"

\* Append n chars; becomes the last delta
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastDeltaLen' = n
  /\ lastOp' = "commit"
  /\ UNCHANGED clipboardLen

\* Duplicate last delta: clipboard holds it; buffer grows by it; delta unchanged
Duplicate ==
  /\ lastDeltaLen > 0
  /\ bufferLen + lastDeltaLen <= MaxLen
  /\ bufferLen' = bufferLen + lastDeltaLen
  /\ clipboardLen' = lastDeltaLen
  /\ lastDeltaLen' = lastDeltaLen
  /\ lastOp' = "duplicate"

\* No-op when nothing to duplicate
DuplicateEmpty ==
  /\ lastDeltaLen = 0
  /\ UNCHANGED vars

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ Duplicate
  \/ DuplicateEmpty

Spec == Init /\ [][Next]_vars

----
\* After Duplicate: clipboard holds lastDelta; buffer still covers that delta
\* (buffer grew by lastDeltaLen; post-state has lastDeltaLen <= bufferLen via TypeOK)
DuplicateHoldsDelta ==
  lastOp = "duplicate" =>
    /\ clipboardLen = lastDeltaLen
    /\ lastDeltaLen > 0
    /\ lastDeltaLen <= bufferLen

Inv ==
  /\ TypeOK
  /\ DuplicateHoldsDelta

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~DuplicateHoldsDelta

StateConstraint == bufferLen <= MaxLen

====
