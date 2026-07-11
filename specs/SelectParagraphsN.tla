---- MODULE SelectParagraphsN ----
(*
  "Select up/down N paragraphs": span N paragraphs from caret; buffer unchanged.

  Dual of:
    DictationCommand.selectUpParagraphs / selectDownParagraphs
    TranscriptSelection.selectParagraphsSpan
    AppState.performSelectParagraphs

  Grain: bufferLen unchanged; lastN = paragraphs in selection.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  prevBufferLen,
  lastOp,   \* "none" | "commit" | "selectParas"
  lastN

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 6
MaxN == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "selectParas"}
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

SelectParagraphsN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "selectParas"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectParagraphsN

Spec == Init /\ [][Next]_vars

----
SelectPreservesBuffer ==
  lastOp = "selectParas" => bufferLen = prevBufferLen

SelectCountPositive ==
  lastOp = "selectParas" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer
  /\ SelectCountPositive

BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
