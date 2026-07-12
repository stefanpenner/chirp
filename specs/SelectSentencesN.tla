---- MODULE SelectSentencesN ----
(*
  "Select up/down N sentences": span N sentences from caret; buffer unchanged.

  Dual of:
    DictationCommand.selectUpSentences / selectDownSentences
    TranscriptSelection.selectSentencesSpan
    AppState.performSelectSentences

  Grain: bufferLen unchanged; lastN = sentences in selection.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "selectSents"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "selectSents"}
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

SelectSentencesN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "selectSents"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectSentencesN

Spec == Init /\ [][Next]_vars

----
SelectPreservesBuffer ==
  lastOp = "selectSents" => bufferLen = prevBufferLen

SelectCountPositive ==
  lastOp = "selectSents" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer
  /\ SelectCountPositive

BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
