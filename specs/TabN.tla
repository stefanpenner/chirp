---- MODULE TabN ----
(*
  Dragon "Tab <n> times": insert N tab characters into the session buffer.

  Dual of:
    DictationCommand.pressTab(count)
    AppState.performPressTab

  Grain: bufferLen grows by min(N, room). lastN records tabs applied.
*)

EXTENDS Integers, TLC

CONSTANTS MaxLen, MaxN

VARIABLES
  bufferLen,
  lastOp,   \* "none" | "commit" | "tab"
  lastN     \* tabs inserted last (0 if none)

vars == <<bufferLen, lastOp, lastN>>

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "tab"}
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

\* Insert k tabs (k ≥ 1), clamped to remaining room
TabN(k) ==
  /\ k \in 1..MaxN
  /\ bufferLen < MaxLen
  /\ LET room == MaxLen - bufferLen
         peeled == IF k <= room THEN k ELSE room
     IN /\ peeled >= 1
        /\ bufferLen' = bufferLen + peeled
        /\ lastOp' = "tab"
        /\ lastN' = peeled

Reset ==
  /\ bufferLen' = 0
  /\ lastOp' = "none"
  /\ lastN' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E k \in 1..MaxN: TabN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
TabSafe ==
  lastOp = "tab" =>
    /\ lastN >= 1
    /\ lastN <= MaxN
    /\ bufferLen >= lastN

Inv ==
  /\ TypeOK
  /\ TabSafe

BaitInv == ~TabSafe

StateConstraint == bufferLen <= MaxLen

====
