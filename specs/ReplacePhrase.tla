---- MODULE ReplacePhrase ----
(*
  Single-utterance "replace X with Y": last match of targetLen is
  spliced with replLen. No-match is a no-op.

  Dual of:
    PhraseReplaceDecision.findLastRange / bufferAfterReplace
    AppState.performReplacePhrase

  Grain: abstract lengths (not string content).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* whether last find would succeed
  targetLen,     \* length of match when hasMatch
  lastOp,        \* "none" | "commit" | "replace" | "miss"
  typedToApp     \* mirrors textLen

vars == <<textLen, hasMatch, targetLen, lastOp, typedToApp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ targetLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "replace", "miss"}
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
  /\ \* After commit, may or may not contain a match
     \/ /\ hasMatch' = FALSE
        /\ targetLen' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E t \in 1..textLen':
             targetLen' = t

\* Successful replace: peel targetLen, add repl
ReplaceHit(repl) ==
  /\ hasMatch
  /\ targetLen > 0
  /\ repl \in 1..MaxLen
  /\ LET base == textLen - targetLen
     IN /\ base + repl <= MaxLen
        /\ textLen' = base + repl
        /\ typedToApp' = base + repl
        /\ lastOp' = "replace"
        /\ hasMatch' = FALSE
        /\ targetLen' = 0

\* Miss: no mutation
ReplaceMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, targetLen, typedToApp>>

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E r \in 1..MaxLen: ReplaceHit(r)
  \/ ReplaceMiss

Spec == Init /\ [][Next]_vars

----
TypedMatchesText == typedToApp = textLen

MissPreserves ==
  lastOp = "miss" => typedToApp = textLen

Inv ==
  /\ TypeOK
  /\ TypedMatchesText
  /\ MissPreserves

BaitInv == ~TypedMatchesText

StateConstraint == textLen <= MaxLen

====
