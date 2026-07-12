---- MODULE MoveSentencesN ----
(*
  Dragon-style "move up/down N sentences": jump to sentence start N steps away.

  Dual of:
    DictationCommand.moveUpSentences / moveDownSentences
    TranscriptSelection.offsetAfterSentenceMove
    AppState.performMoveSentences

  Grain: bufferLen unchanged; lastN records sentences stepped.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "moveSents"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "moveSents"}
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

MoveSentencesN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "moveSents"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MoveSentencesN

Spec == Init /\ [][Next]_vars

----
MovePreservesBuffer ==
  lastOp = "moveSents" => bufferLen = prevBufferLen

MoveCountPositive ==
  lastOp = "moveSents" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ MovePreservesBuffer
  /\ MoveCountPositive

BaitInv == ~MovePreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
