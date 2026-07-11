---- MODULE GoToPhrase ----
(*
  Single-utterance "go to X" / "go after X": last match moves abstract caret.
  Buffer length is unchanged. Selection is not armed. Miss is a no-op.

  Dual of:
    PhraseReplaceDecision.findLastRange
    AppState.performGoToPhrase

  Grain: abstract lengths (not string content).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* whether last find would succeed
  targetLen,     \* length of match when hasMatch
  caret,         \* abstract caret offset (0..textLen); -1 = unknown/end
  lastOp         \* "none" | "commit" | "goTo" | "goAfter" | "miss"

vars == <<textLen, hasMatch, targetLen, caret, lastOp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ targetLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "goTo", "goAfter", "miss"}
  /\ hasMatch => (targetLen > 0 /\ targetLen <= textLen)
  /\ ~hasMatch => targetLen = 0
  /\ caret = -1 \/ caret <= textLen

Init ==
  /\ textLen = 0
  /\ hasMatch = FALSE
  /\ targetLen = 0
  /\ caret = -1
  /\ lastOp = "none"

----
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ caret' = textLen'   \* append lands at end
  /\ lastOp' = "commit"
  /\ \/ /\ hasMatch' = FALSE
        /\ targetLen' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E t \in 1..textLen':
             targetLen' = t

\* Go to start of match; buffer unchanged
GoToHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ \E start \in 0..MaxLen:
       /\ start + targetLen <= textLen
       /\ caret' = start
       /\ lastOp' = "goTo"
       /\ UNCHANGED <<textLen, hasMatch, targetLen>>

\* Go after end of match; buffer unchanged
GoAfterHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ \E start \in 0..MaxLen:
       /\ start + targetLen <= textLen
       /\ caret' = start + targetLen
       /\ lastOp' = "goAfter"
       /\ UNCHANGED <<textLen, hasMatch, targetLen>>

\* Miss: no mutation
GoMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, targetLen, caret>>

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ GoToHit
  \/ GoAfterHit
  \/ GoMiss

Spec == Init /\ [][Next]_vars

----
GoPreservesBuffer ==
  lastOp \in {"goTo", "goAfter", "miss"} => TRUE

CaretInRange ==
  caret = -1 \/ (caret >= 0 /\ caret <= textLen)

Inv ==
  /\ TypeOK
  /\ CaretInRange

BaitInv == ~CaretInRange

StateConstraint == textLen <= MaxLen

====
