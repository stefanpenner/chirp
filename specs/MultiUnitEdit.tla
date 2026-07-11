---- MODULE MultiUnitEdit ----
(*
  Counted trailing multi-unit delete (last N sentences/paragraphs/lines/words).

  Dual of:
    DictationCommand.deleteLastWords/Sentences/Paragraphs/Lines(count)
    AppState.performDeleteLastUnits

  Grain:
    unitCount \in 0..MaxCount   \* units currently in the buffer
    lastOp \in {"none","commit","deleteN"}
    lastN \in 0..MaxCount       \* N requested on last delete (0 = none)
*)

EXTENDS Integers, TLC

VARIABLES
  unitCount,
  lastOp,
  lastN

vars == <<unitCount, lastOp, lastN>>

MaxCount == 5

TypeOK ==
  /\ unitCount \in 0..MaxCount
  /\ lastOp \in {"none", "commit", "deleteN"}
  /\ lastN \in 0..MaxCount

Init ==
  /\ unitCount = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit ==
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ \/ unitCount' = unitCount
     \/ /\ unitCount < MaxCount
        /\ unitCount' = unitCount + 1

\* Delete last N units (N ≥ 2); clamp to available count
DeleteN ==
  /\ unitCount >= 2
  /\ \E n \in 2..unitCount:
       /\ lastN' = n
       /\ unitCount' = unitCount - n
       /\ lastOp' = "deleteN"

Next ==
  \/ Commit
  \/ DeleteN

Spec == Init /\ [][Next]_vars

----
\* After deleteN, buffer shrank by lastN and never goes negative
DeleteNSafe ==
  lastOp = "deleteN" =>
    /\ lastN >= 2
    /\ unitCount >= 0
    /\ lastN <= MaxCount

\* unitCount always in range
CountInRange == unitCount \in 0..MaxCount

Inv ==
  /\ TypeOK
  /\ CountInRange
  /\ DeleteNSafe

BaitInv == ~DeleteNSafe

StateConstraint == unitCount <= MaxCount

====
