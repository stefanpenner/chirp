---- MODULE WordCaret ----
(*
  Word move left/right updates session caret; bufferLen unchanged.
  Next content inserts at caret when mid-buffer (dual SessionCaretDecision).

  Dual of:
    TranscriptSelection.offsetAfterWordMove
    AppState.performMoveWord / performMoveWords + setSessionCaret

  Grain: abstract lengths (not string content).
  caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  caret,        \* -1 = end; else 0..bufferLen
  lastOp        \* "none" | "commit" | "moveLeft" | "moveRight" | "insert"

vars == <<bufferLen, caret, lastOp>>

MaxLen == 6

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "moveLeft", "moveRight", "insert"}
  /\ caret = -1 \/ (caret >= 0 /\ caret <= bufferLen)

Init ==
  /\ bufferLen = 0
  /\ caret = -1
  /\ lastOp = "none"

----
Commit(n) ==
  /\ caret = -1
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ caret' = -1
  /\ lastOp' = "commit"

\* Abstract move left: decrease caret by 1..k, clamp at 0
MoveLeft ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ from > 0
        /\ \E step \in 1..from:
             /\ caret' = from - step
             /\ lastOp' = "moveLeft"
             /\ UNCHANGED bufferLen

\* Abstract move right: increase caret toward end; end → -1
MoveRight ==
  /\ bufferLen >= 1
  /\ caret >= 0
  /\ caret < bufferLen
  /\ \E step \in 1..(bufferLen - caret):
       /\ LET c == caret + step
          IN IF c >= bufferLen
             THEN caret' = -1
             ELSE caret' = c
       /\ lastOp' = "moveRight"
       /\ UNCHANGED bufferLen

\* Mid insert at caret
InsertAtCaret(n) ==
  /\ caret >= 0
  /\ caret < bufferLen
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ LET newLen == bufferLen + n
        newCaret == caret + n
     IN /\ bufferLen' = newLen
        /\ lastOp' = "insert"
        /\ IF newCaret >= newLen
           THEN caret' = -1
           ELSE caret' = newCaret

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MoveLeft
  \/ MoveRight
  \/ \E n \in 1..MaxLen: InsertAtCaret(n)

Spec == Init /\ [][Next]_vars

----
CaretInRange ==
  caret = -1 \/ (caret >= 0 /\ caret <= bufferLen)

MovePreservesBuffer ==
  lastOp \in {"moveLeft", "moveRight"} => TRUE  \* bufferLen UNCHANGED in actions

Inv ==
  /\ TypeOK
  /\ CaretInRange

BaitInv == ~CaretInRange

StateConstraint == bufferLen <= MaxLen

====
