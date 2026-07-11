---- MODULE WordCursor ----
(*
  Progressive word navigation index (select next/previous word walk).

  Dual of:
    AppState.wordNavIndex: Int?   \* nil = end / unknown (dual of index = -1)
    DictationCommand select next/previous word progressive path
    TranscriptSelection.wordRanges

  Grain:
    wordCount \in 0..MaxCount
    index = -1 means caret/selection at end (no progressive walk)
    index \in 0..(wordCount-1) means word under selection (0-based)
*)

EXTENDS Integers, TLC

VARIABLES
  wordCount,
  index,
  lastOp

vars == <<wordCount, index, lastOp>>

MaxCount == 5

TypeOK ==
  /\ wordCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ lastOp \in {"none", "commit", "next", "prev", "last"}

IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < wordCount

Init ==
  /\ wordCount = 0
  /\ index = -1
  /\ lastOp = "none"

----
Commit ==
  /\ lastOp' = "commit"
  /\ index' = -1
  /\ \/ wordCount' = wordCount
     \/ /\ wordCount < MaxCount
        /\ wordCount' = wordCount + 1

\* Select next: from end with caret would land via external caret; from index advance
NextWord ==
  /\ wordCount >= 1
  /\ IF index = -1
     THEN index' = 0
     ELSE /\ index < wordCount - 1
          /\ index' = index + 1
  /\ lastOp' = "next"
  /\ UNCHANGED wordCount

PrevWord ==
  /\ wordCount >= 1
  /\ IF index = -1
     THEN index' = wordCount - 1
     ELSE /\ index > 0
          /\ index' = index - 1
  /\ lastOp' = "prev"
  /\ UNCHANGED wordCount

SelectLast ==
  /\ wordCount >= 1
  /\ index' = wordCount - 1
  /\ lastOp' = "last"
  /\ UNCHANGED wordCount

Next ==
  \/ Commit
  \/ NextWord
  \/ PrevWord
  \/ SelectLast

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ IndexInRange

BaitInv == ~IndexInRange

StateConstraint == wordCount <= MaxCount

====
