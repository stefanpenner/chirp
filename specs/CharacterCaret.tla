---- MODULE CharacterCaret ----
(*
  Character move left/right updates session caret; bufferLen unchanged.
  Next content inserts at caret when mid-buffer.

  Dual of:
    TranscriptSelection.offsetAfterCharacterMove
    AppState.performMoveCharacters + setSessionCaret

  Grain: abstract lengths. caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  caret,        \* -1 = end; else 0..bufferLen
  lastOp        \* "none" | "commit" | "moveLeft" | "moveRight" | "insert"

vars == <<bufferLen, caret, lastOp>>

MaxLen == 8

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

\* Move left by step chars from end or caret
MoveLeft ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ from > 0
        /\ \E step \in 1..from:
             /\ caret' = from - step
             /\ lastOp' = "moveLeft"
             /\ UNCHANGED bufferLen

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

Inv ==
  /\ TypeOK
  /\ CaretInRange

BaitInv == ~CaretInRange

StateConstraint == bufferLen <= MaxLen

====
