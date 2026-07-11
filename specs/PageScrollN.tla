---- MODULE PageScrollN ----
(*
  "Page up/down N times": host Page Up/Down × N; session buffer unchanged.

  Dual of:
    DictationCommand.pageUp / pageDown (count)
    AppState.performScrollPage(count:)
    TextInserter.scrollPage

  Grain: bufferLen only. Page scroll never mutates transcript.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "pageScroll"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "pageScroll"}
  /\ lastN \in 0..MaxN

Init ==
  /\ bufferLen = 0
  /\ prevBufferLen = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ UNCHANGED prevBufferLen

PageScrollN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "pageScroll"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ PageScrollN

Spec == Init /\ [][Next]_vars

----
ScrollPreservesBuffer ==
  lastOp = "pageScroll" => bufferLen = prevBufferLen

ScrollCountPositive ==
  lastOp = "pageScroll" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ ScrollPreservesBuffer
  /\ ScrollCountPositive

BaitInv == ~ScrollPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
