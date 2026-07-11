---- MODULE MoveParagraphsN ----
(*
  Dragon "move up/down N paragraphs": jump to paragraph start N steps away.

  Dual of:
    DictationCommand.moveUpParagraphs / moveDownParagraphs
    TranscriptSelection.offsetAfterParagraphMove
    AppState.performMoveParagraphs

  Grain: bufferLen unchanged; lastN records paragraphs stepped.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "moveParas"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "moveParas"}
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

MoveParagraphsN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "moveParas"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MoveParagraphsN

Spec == Init /\ [][Next]_vars

----
MovePreservesBuffer ==
  lastOp = "moveParas" => bufferLen = prevBufferLen

MoveCountPositive ==
  lastOp = "moveParas" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ MovePreservesBuffer
  /\ MoveCountPositive

BaitInv == ~MovePreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
