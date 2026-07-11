---- MODULE DeletePhrase ----
(*
  Single-utterance "delete X": last match of targetLen is removed
  (replLen = 0). No-match is a no-op.

  Dual of:
    PhraseReplaceDecision.findLastDeletableRange / bufferAfterDelete
    AppState.performDeletePhrase

  Grain: abstract lengths (not string content).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* whether last find would succeed
  targetLen,     \* length of match when hasMatch (may include absorbed space)
  lastOp,        \* "none" | "commit" | "delete" | "miss"
  typedToApp     \* mirrors textLen

vars == <<textLen, hasMatch, targetLen, lastOp, typedToApp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ targetLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "delete", "miss"}
  /\ typedToApp \in 0..MaxLen
  /\ typedToApp = textLen
  /\ hasMatch => (targetLen > 0 /\ targetLen <= textLen)
  /\ ~hasMatch => targetLen = 0

Init ==
  /\ textLen = 0
  /\ hasMatch = FALSE
  /\ targetLen = 0
  /\ lastOp = "none"
  /\ typedToApp = 0

----
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ typedToApp' = typedToApp + n
  /\ lastOp' = "commit"
  /\ \/ /\ hasMatch' = FALSE
        /\ targetLen' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E t \in 1..textLen':
             targetLen' = t

\* Successful delete: peel targetLen
DeleteHit ==
  /\ hasMatch
  /\ targetLen > 0
  /\ textLen' = textLen - targetLen
  /\ typedToApp' = typedToApp - targetLen
  /\ lastOp' = "delete"
  /\ hasMatch' = FALSE
  /\ targetLen' = 0

\* Miss: no mutation
DeleteMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, targetLen, typedToApp>>

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ DeleteHit
  \/ DeleteMiss

Spec == Init /\ [][Next]_vars

----
TypedMatchesText == typedToApp = textLen

MissPreserves ==
  lastOp = "miss" => typedToApp = textLen

DeleteShrinks ==
  lastOp = "delete" => textLen >= 0

Inv ==
  /\ TypeOK
  /\ TypedMatchesText
  /\ MissPreserves
  /\ DeleteShrinks

BaitInv == ~TypedMatchesText

StateConstraint == textLen <= MaxLen

====
