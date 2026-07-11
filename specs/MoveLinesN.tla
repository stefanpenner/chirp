---- MODULE MoveLinesN ----
(*
  Dragon "move up/down N lines": host ↑/↓ × N; session buffer unchanged.

  Dual of:
    DictationCommand.moveUpLines / moveDownLines
    AppState.performMoveLine(count:)
    TranscriptSelection.offsetAfterLineMove(..., count:)

  Grain: bufferLen only. Multi-line move never mutates transcript length.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "moveLines"
  lastN     \* lines moved (1..MaxN)

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "moveLines"}
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

\* Move N lines up or down — keyboard only; buffer length frozen
MoveLinesN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "moveLines"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MoveLinesN

Spec == Init /\ [][Next]_vars

----
MovePreservesBuffer ==
  lastOp = "moveLines" => bufferLen = prevBufferLen

MoveCountPositive ==
  lastOp = "moveLines" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ MovePreservesBuffer
  /\ MoveCountPositive

BaitInv == ~MovePreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
