---- MODULE LineCaret ----
(*
  Line / document moves update session caret; bufferLen unchanged.
  Next content inserts at caret when mid-buffer (dual SessionCaretDecision).

  Dual of:
    TranscriptSelection.offsetAfterLineMove / offsetAtLineStart / offsetAtLineEnd
    AppState.performMoveLine / performMoveToLineStart|End / DocumentStart|End

  Grain: abstract lengths (not string content).
  caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  caret,        \* -1 = end; else 0..bufferLen
  lastOp        \* "none" | "commit" | "lineUp" | "lineDown" | "lineStart" | "lineEnd" | "docStart" | "docEnd" | "insert"

vars == <<bufferLen, caret, lastOp>>

MaxLen == 6

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "lineUp", "lineDown", "lineStart", "lineEnd", "docStart", "docEnd", "insert"}
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

\* Abstract line up: decrease caret toward 0
LineUp ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ from > 0
        /\ \E step \in 1..from:
             /\ caret' = from - step
             /\ lastOp' = "lineUp"
             /\ UNCHANGED bufferLen

\* Abstract line down: increase caret toward end; end → -1
LineDown ==
  /\ bufferLen >= 1
  /\ caret >= 0
  /\ caret < bufferLen
  /\ \E step \in 1..(bufferLen - caret):
       /\ LET c == caret + step
          IN IF c >= bufferLen
             THEN caret' = -1
             ELSE caret' = c
       /\ lastOp' = "lineDown"
       /\ UNCHANGED bufferLen

LineStart ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ \E start \in 0..from:
          /\ caret' = start
          /\ lastOp' = "lineStart"
          /\ UNCHANGED bufferLen

LineEnd ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ from < bufferLen
        /\ \E endPos \in from..bufferLen:
             /\ IF endPos >= bufferLen
                THEN caret' = -1
                ELSE caret' = endPos
             /\ lastOp' = "lineEnd"
             /\ UNCHANGED bufferLen

DocStart ==
  /\ bufferLen >= 1
  /\ caret' = 0
  /\ lastOp' = "docStart"
  /\ UNCHANGED bufferLen

DocEnd ==
  /\ caret' = -1
  /\ lastOp' = "docEnd"
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
  \/ LineUp
  \/ LineDown
  \/ LineStart
  \/ LineEnd
  \/ DocStart
  \/ DocEnd
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
