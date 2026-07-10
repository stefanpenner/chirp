---- MODULE PageScroll ----
(*
  Page Up / Page Down must not mutate the session buffer.

  Dual of DictationCommand.pageUp / pageDown + AppState.performScrollPage
  (TextInserter.scrollPage only; transcribedText unchanged).

  Grain: bufferLen only (0..4). Scroll actions leave bufferLen unchanged.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  prevBufferLen,  \* bufferLen before last scroll (for inv)
  lastOp          \* "none" | "commit" | "scroll"

vars == <<bufferLen, prevBufferLen, lastOp>>

MaxLen == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "scroll"}

Init ==
  /\ bufferLen = 0
  /\ prevBufferLen = 0
  /\ lastOp = "none"

----
\* Normal dictation commit grows the buffer
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastOp' = "commit"
  /\ UNCHANGED prevBufferLen

\* Page Up — keyboard scroll only; session buffer unchanged
PageUp ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "scroll"
  /\ UNCHANGED bufferLen

\* Page Down — same contract
PageDown ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "scroll"
  /\ UNCHANGED bufferLen

\* Generic scroll (either direction)
Scroll ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "scroll"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ PageUp
  \/ PageDown
  \/ Scroll

Spec == Init /\ [][Next]_vars

----
\* After any scroll op, buffer length equals pre-scroll length
ScrollPreservesBuffer ==
  lastOp = "scroll" => bufferLen = prevBufferLen

Inv ==
  /\ TypeOK
  /\ ScrollPreservesBuffer

\* Bait: claim scroll may change the buffer (must FAIL under TLC)
BaitInv == ~ScrollPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
