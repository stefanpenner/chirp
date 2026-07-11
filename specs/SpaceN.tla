---- MODULE SpaceN ----
(*
  "Press space N times": insert N spaces into the session buffer.

  Dual of:
    DictationCommand.pressSpace(count)
    AppState.performPressSpace

  Grain: bufferLen grows by min(N, room). lastN records spaces applied.
*)

EXTENDS Integers, TLC

CONSTANTS MaxLen, MaxN

VARIABLES
  bufferLen,
  lastOp,   \* "none" | "commit" | "space"
  lastN

vars == <<bufferLen, lastOp, lastN>>

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "space"}
  /\ lastN \in 0..MaxN

Init ==
  /\ bufferLen = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastOp' = "commit"
  /\ lastN' = 0

SpaceN(k) ==
  /\ k \in 1..MaxN
  /\ bufferLen < MaxLen
  /\ LET room == MaxLen - bufferLen
         peeled == IF k <= room THEN k ELSE room
     IN /\ peeled >= 1
        /\ bufferLen' = bufferLen + peeled
        /\ lastOp' = "space"
        /\ lastN' = peeled

Reset ==
  /\ bufferLen' = 0
  /\ lastOp' = "none"
  /\ lastN' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E k \in 1..MaxN: SpaceN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
SpaceSafe ==
  lastOp = "space" =>
    /\ lastN >= 1
    /\ lastN <= MaxN
    /\ bufferLen >= lastN

Inv ==
  /\ TypeOK
  /\ SpaceSafe

BaitInv == ~SpaceSafe

StateConstraint == bufferLen <= MaxLen

====
