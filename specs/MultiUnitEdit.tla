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
  index,       \* -1 = end; else 0-based unit under caret
  lastOp,
  lastN

vars == <<unitCount, index, lastOp, lastN>>

MaxCount == 5

TypeOK ==
  /\ unitCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ lastOp \in {"none", "commit", "deleteLastN", "deleteNextN"}
  /\ lastN \in 0..MaxCount

IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < unitCount

Init ==
  /\ unitCount = 0
  /\ index = -1
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit ==
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ index' = -1
  /\ \/ unitCount' = unitCount
     \/ /\ unitCount < MaxCount
        /\ unitCount' = unitCount + 1

\* Delete last N units (N ≥ 2); clamp to available count; reset caret
DeleteLastN ==
  /\ unitCount >= 2
  /\ \E n \in 2..unitCount:
       /\ lastN' = n
       /\ unitCount' = unitCount - n
       /\ index' = -1
       /\ lastOp' = "deleteLastN"

\* Delete next N units from end (start at unit 1) or after index
DeleteNextN ==
  /\ unitCount >= 2
  /\ LET start == IF index = -1 THEN 1 ELSE index + 1 IN
     /\ start < unitCount
     /\ \E n \in 2..(unitCount - start):
          /\ lastN' = n
          /\ unitCount' = unitCount - n
          /\ index' = -1
          /\ lastOp' = "deleteNextN"

Next ==
  \/ Commit
  \/ DeleteLastN
  \/ DeleteNextN

Spec == Init /\ [][Next]_vars

----
DeleteNSafe ==
  lastOp \in {"deleteLastN", "deleteNextN"} =>
    /\ lastN >= 2
    /\ unitCount >= 0
    /\ lastN <= MaxCount
    /\ index = -1

CountInRange == unitCount \in 0..MaxCount

Inv ==
  /\ TypeOK
  /\ CountInRange
  /\ IndexInRange
  /\ DeleteNSafe

BaitInv == ~DeleteNSafe

StateConstraint == unitCount <= MaxCount

====
