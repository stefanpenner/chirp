---- MODULE CharacterEdit ----
(*
  Counted character delete from session buffer (previous/last N characters).

  Dual of:
    DictationCommand.deletePreviousCharacters(count)
    AppState.performDeletePreviousCharacters

  Grain:
    bufferLen \in 0..MaxLen
    lastOp \in {"none","commit","deletePrev"}
    lastN \in 0..MaxLen
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,
  lastOp,
  lastN

vars == <<bufferLen, lastOp, lastN>>

MaxLen == 10

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "deletePrev"}
  /\ lastN \in 0..MaxLen

Init ==
  /\ bufferLen = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit ==
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ \/ bufferLen' = bufferLen
     \/ /\ bufferLen < MaxLen
        /\ bufferLen' = bufferLen + 1

\* Delete previous N characters; clamp to bufferLen
DeletePrev ==
  /\ bufferLen >= 1
  /\ \E n \in 1..bufferLen:
       /\ lastN' = n
       /\ bufferLen' = bufferLen - n
       /\ lastOp' = "deletePrev"

Next ==
  \/ Commit
  \/ DeletePrev

Spec == Init /\ [][Next]_vars

----
DeletePrevSafe ==
  lastOp = "deletePrev" =>
    /\ lastN >= 1
    /\ bufferLen >= 0
    /\ lastN <= MaxLen

Inv ==
  /\ TypeOK
  /\ DeletePrevSafe

BaitInv == ~DeletePrevSafe

StateConstraint == bufferLen <= MaxLen

====
