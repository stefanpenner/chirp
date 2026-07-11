---- MODULE EnterN ----
(*
  Dragon "press enter N times": insert N newlines into the session buffer.

  Dual of:
    DictationCommand.pressEnter(count)
    AppState.performPressEnter

  Grain: bufferLen grows by min(N, room). lastN records newlines applied.
  (Host types Return via TextInserter.steps — buffer length dual only.)
*)

EXTENDS Integers, TLC

CONSTANTS MaxLen, MaxN

VARIABLES
  bufferLen,
  lastOp,   \* "none" | "commit" | "enter"
  lastN

vars == <<bufferLen, lastOp, lastN>>

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "enter"}
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

EnterN(k) ==
  /\ k \in 1..MaxN
  /\ bufferLen < MaxLen
  /\ LET room == MaxLen - bufferLen
         peeled == IF k <= room THEN k ELSE room
     IN /\ peeled >= 1
        /\ bufferLen' = bufferLen + peeled
        /\ lastOp' = "enter"
        /\ lastN' = peeled

Reset ==
  /\ bufferLen' = 0
  /\ lastOp' = "none"
  /\ lastN' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E k \in 1..MaxN: EnterN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
EnterSafe ==
  lastOp = "enter" =>
    /\ lastN >= 1
    /\ lastN <= MaxN
    /\ bufferLen >= lastN

Inv ==
  /\ TypeOK
  /\ EnterSafe

BaitInv == ~EnterSafe

StateConstraint == bufferLen <= MaxLen

====
