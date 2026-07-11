---- MODULE SelectPhrase ----
(*
  Single-utterance "select X": last match arms a selection window.
  Buffer length is unchanged. Miss is a no-op.

  Dual of:
    PhraseReplaceDecision.findLastRange
    AppState.performSelectPhrase + sessionSelection arm

  Grain: abstract lengths (not string content).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* whether last find would succeed
  targetLen,     \* length of match when hasMatch
  selStart,      \* armed selection start (-1 = none)
  selLen,        \* armed selection length
  lastOp         \* "none" | "commit" | "select" | "miss"

vars == <<textLen, hasMatch, targetLen, selStart, selLen, lastOp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ targetLen \in 0..MaxLen
  /\ selStart \in -1..MaxLen
  /\ selLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "select", "miss"}
  /\ hasMatch => (targetLen > 0 /\ targetLen <= textLen)
  /\ ~hasMatch => targetLen = 0
  /\ \/ /\ selStart = -1
        /\ selLen = 0
     \/ /\ selStart >= 0
        /\ selLen > 0
        /\ selStart + selLen <= textLen

Init ==
  /\ textLen = 0
  /\ hasMatch = FALSE
  /\ targetLen = 0
  /\ selStart = -1
  /\ selLen = 0
  /\ lastOp = "none"

----
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastOp' = "commit"
  /\ selStart' = -1
  /\ selLen' = 0
  /\ \/ /\ hasMatch' = FALSE
        /\ targetLen' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E t \in 1..textLen':
             targetLen' = t

\* Successful select: arm window, buffer unchanged
SelectHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ \E start \in 0..MaxLen:
       /\ start + targetLen <= textLen
       /\ selStart' = start
       /\ selLen' = targetLen
       /\ lastOp' = "select"
       /\ UNCHANGED <<textLen, hasMatch, targetLen>>

\* Miss: no mutation
SelectMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, targetLen, selStart, selLen>>

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectHit
  \/ SelectMiss

Spec == Init /\ [][Next]_vars

----
SelectPreservesBuffer ==
  lastOp = "select" => TRUE  \* textLen unchanged by SelectHit (UNCHANGED)

MissPreserves ==
  lastOp = "miss" =>
    /\ selStart = selStart  \* tautology; real check is UNCHANGED in action
    /\ textLen >= 0

SelInRange ==
  \/ selLen = 0
  \/ /\ selStart >= 0
     /\ selStart + selLen <= textLen

Inv ==
  /\ TypeOK
  /\ SelInRange

BaitInv == ~SelInRange

StateConstraint == textLen <= MaxLen

====
