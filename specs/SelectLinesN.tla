---- MODULE SelectLinesN ----
(*
  "Select up/down N lines": host ⇧↑/↓ × N; session buffer unchanged.

  Dual of:
    DictationCommand.selectUpLines / selectDownLines
    AppState.performSelectLines
    TextInserter.selectLine

  Grain: bufferLen only. Line select is keyboard-only — never mutates transcript.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "selectLines"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "selectLines"}
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

SelectLinesN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "selectLines"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectLinesN

Spec == Init /\ [][Next]_vars

----
SelectPreservesBuffer ==
  lastOp = "selectLines" => bufferLen = prevBufferLen

SelectCountPositive ==
  lastOp = "selectLines" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer
  /\ SelectCountPositive

BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
