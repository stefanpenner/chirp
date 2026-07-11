---- MODULE LineCursor ----
(*
  Progressive line navigation index (select / delete / move next line).

  Dual of:
    AppState.lineNavIndex: Int?   \* nil = at end (dual of index = -1)
    DictationCommand select/delete next line progressive path
    AppState.performMoveToNextLine / performMoveToPreviousLine
    TranscriptSelection.lineRanges

  Grain:
    lineCount \in 0..MaxCount
    index = -1 means caret at end of buffer
    index \in 0..(lineCount-1) means line under caret (0-based)

  Product (move, mirrors next sentence):
    - next from end: index' = 1 (second line) when lineCount >= 2
    - previous from end: index' = lineCount - 1
    - Buffer length unchanged on move (caret only; insert dual = SessionCaret)
*)

EXTENDS Integers, TLC

VARIABLES
  lineCount,  \* number of lines in the session buffer
  index,      \* -1 = end; else 0-based line under caret
  lastOp      \* "none" | "commit" | "next" | "prev" | "delete"

vars == <<lineCount, index, lastOp>>

MaxCount == 4

TypeOK ==
  /\ lineCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ lastOp \in {"none", "commit", "next", "prev", "delete"}

IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < lineCount

Init ==
  /\ lineCount = 0
  /\ index = -1
  /\ lastOp = "none"

----
Commit ==
  /\ lastOp' = "commit"
  /\ index' = -1
  /\ \/ lineCount' = lineCount
     \/ /\ lineCount < MaxCount
        /\ lineCount' = lineCount + 1

NextLine ==
  /\ lineCount >= 2
  /\ IF index = -1
     THEN index' = 1
     ELSE /\ index < lineCount - 1
          /\ index' = index + 1
  /\ lastOp' = "next"
  /\ UNCHANGED lineCount

\* Progressive prev: from end land on last line; else step back while > 0
PrevLine ==
  /\ lineCount >= 1
  /\ IF index = -1
     THEN index' = lineCount - 1
     ELSE /\ index > 0
          /\ index' = index - 1
  /\ lastOp' = "prev"
  /\ UNCHANGED lineCount

DeleteNextLine ==
  /\ lineCount >= 2
  /\ IF index = -1
     THEN TRUE
     ELSE index < lineCount - 1
  /\ lastOp' = "delete"
  /\ index' = -1
  /\ lineCount' = lineCount - 1

Next ==
  \/ Commit
  \/ NextLine
  \/ PrevLine
  \/ DeleteNextLine

Spec == Init /\ [][Next]_vars

----
NextLandsInRange ==
  lastOp = "next" => (index >= 1 /\ index < lineCount)

PrevLandsInRange ==
  lastOp = "prev" => (index >= 0 /\ index < lineCount)

CommitResetsToEnd ==
  lastOp \in {"commit", "delete"} => index = -1

Inv ==
  /\ TypeOK
  /\ IndexInRange
  /\ NextLandsInRange
  /\ PrevLandsInRange
  /\ CommitResetsToEnd

BaitInv == ~IndexInRange

StateConstraint == lineCount <= MaxCount

====
