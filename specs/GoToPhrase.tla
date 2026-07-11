---- MODULE GoToPhrase ----
(*
  "go to X" / "go after X" set session caret; next content inserts at caret
  (not always append). Buffer dual of host type-at-caret.

  Dual of:
    PhraseReplaceDecision.findLastRange
    AppState.performGoToPhrase + SessionCaretDecision.bufferAfterInsert
    AppState.sessionCaret content path

  Grain: abstract lengths (not string content).
  caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* whether last find would succeed
  targetLen,     \* length of match when hasMatch
  caret,         \* abstract caret (0..textLen); -1 = end (append mode)
  lastOp         \* "none" | "commit" | "goTo" | "goAfter" | "miss" | "insert"

vars == <<textLen, hasMatch, targetLen, caret, lastOp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ targetLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "goTo", "goAfter", "miss", "insert"}
  /\ hasMatch => (targetLen > 0 /\ targetLen <= textLen)
  /\ ~hasMatch => targetLen = 0
  /\ caret = -1 \/ (caret >= 0 /\ caret <= textLen)

Init ==
  /\ textLen = 0
  /\ hasMatch = FALSE
  /\ targetLen = 0
  /\ caret = -1
  /\ lastOp = "none"

----
\* Trailing append when caret is end (-1)
CommitEnd(n) ==
  /\ caret = -1
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ caret' = -1
  /\ lastOp' = "commit"
  /\ \/ /\ hasMatch' = FALSE
        /\ targetLen' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E t \in 1..textLen':
             targetLen' = t

\* Mid-buffer insert at caret; advance caret; switch to end mode if at end
InsertAtCaret(n) ==
  /\ caret >= 0
  /\ caret < textLen
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ LET newLen == textLen + n
        newCaret == caret + n
     IN /\ textLen' = newLen
        /\ lastOp' = "insert"
        /\ hasMatch' = FALSE
        /\ targetLen' = 0
        /\ IF newCaret >= newLen
           THEN caret' = -1
           ELSE caret' = newCaret

GoToHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ \E start \in 0..MaxLen:
       /\ start + targetLen <= textLen
       /\ caret' = start
       /\ lastOp' = "goTo"
       /\ UNCHANGED <<textLen, hasMatch, targetLen>>

GoAfterHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ \E start \in 0..MaxLen:
       /\ start + targetLen <= textLen
       /\ LET c == start + targetLen
          IN IF c >= textLen
             THEN caret' = -1
             ELSE caret' = c
       /\ lastOp' = "goAfter"
       /\ UNCHANGED <<textLen, hasMatch, targetLen>>

GoMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, targetLen, caret>>

Next ==
  \/ \E n \in 1..MaxLen: CommitEnd(n)
  \/ \E n \in 1..MaxLen: InsertAtCaret(n)
  \/ GoToHit
  \/ GoAfterHit
  \/ GoMiss

Spec == Init /\ [][Next]_vars

----
CaretInRange ==
  caret = -1 \/ (caret >= 0 /\ caret <= textLen)

Inv ==
  /\ TypeOK
  /\ CaretInRange

BaitInv == ~CaretInRange

StateConstraint == textLen <= MaxLen

====
