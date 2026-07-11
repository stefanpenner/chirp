---- MODULE SentenceEdge ----
(*
  "start/end of sentence" and "start/end of paragraph" set session caret
  without mutating buffer length. Next content inserts at caret when mid.

  Dual of:
    TranscriptSelection.offsetAtSentenceStart/End / offsetAtParagraphStart/End
    AppState.performMoveToSentenceEdge / performMoveToParagraphEdge

  Grain: abstract lengths. caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  caret,        \* -1 = end; else 0..bufferLen
  lastOp        \* "none" | "commit" | "sentStart" | "sentEnd" | "paraStart" | "paraEnd" | "insert"

vars == <<bufferLen, caret, lastOp>>

MaxLen == 6

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "sentStart", "sentEnd", "paraStart", "paraEnd", "insert"}
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

\* Abstract: move to some offset at/ before current caret (unit start)
UnitStart(op) ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ \E start \in 0..from:
          /\ caret' = start
          /\ lastOp' = op
          /\ UNCHANGED bufferLen

\* Abstract: move to some offset at/ after current caret (unit end)
UnitEnd(op) ==
  /\ bufferLen >= 1
  /\ LET from == IF caret = -1 THEN bufferLen ELSE caret
     IN /\ \E endPos \in from..bufferLen:
          /\ IF endPos >= bufferLen
             THEN caret' = -1
             ELSE caret' = endPos
          /\ lastOp' = op
          /\ UNCHANGED bufferLen

SentenceStart == UnitStart("sentStart")
SentenceEnd == UnitEnd("sentEnd")
ParagraphStart == UnitStart("paraStart")
ParagraphEnd == UnitEnd("paraEnd")

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
  \/ SentenceStart
  \/ SentenceEnd
  \/ ParagraphStart
  \/ ParagraphEnd
  \/ \E n \in 1..MaxLen: InsertAtCaret(n)

Spec == Init /\ [][Next]_vars

----
CaretInRange ==
  caret = -1 \/ (caret >= 0 /\ caret <= bufferLen)

\* Edge moves do not grow the buffer
EdgePreservesLen ==
  lastOp \in {"sentStart", "sentEnd", "paraStart", "paraEnd"} => bufferLen = bufferLen

Inv ==
  /\ TypeOK
  /\ CaretInRange

BaitInv == ~CaretInRange

StateConstraint == bufferLen <= MaxLen

====
