---- MODULE WordCursor ----
(*
  Progressive word navigation index (select next/previous word walk).

  Dual of:
    AppState.wordNavIndex: Int?   \* nil = end / unknown (dual of index = -1)
    AppState.sessionCaret mid-buffer (hasMidCaret)
    DictationCommand select next/previous word progressive path
    TranscriptSelection.wordRanges / nextWordsRange

  Product behavior (AppState.performSelectWords):
    - From end (index = -1, ~hasMidCaret): keyboard ⇧⌥→ fallback;
      index stays -1 (lastOp = "keyboard"). Does NOT jump to word 0.
    - From mid caret (index = -1, hasMidCaret): arm first word at/after
      caret → index becomes some valid word index (modeled as 0..wordCount-1).
    - From progressive index: advance / step back while in range.
    - Select last: index = wordCount - 1.

  Grain:
    wordCount \in 0..MaxCount
    index = -1 means no progressive walk (end / unknown)
    index \in 0..(wordCount-1) means word under selection (0-based)
    hasMidCaret: sessionCaret is mid-buffer (not end)
*)

EXTENDS Integers, TLC

VARIABLES
  wordCount,
  index,
  hasMidCaret,
  lastOp

vars == <<wordCount, index, hasMidCaret, lastOp>>

MaxCount == 5

TypeOK ==
  /\ wordCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ hasMidCaret \in BOOLEAN
  /\ lastOp \in {"none", "commit", "next", "prev", "last", "keyboard", "setMid", "clearMid"}

IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < wordCount

Init ==
  /\ wordCount = 0
  /\ index = -1
  /\ hasMidCaret = FALSE
  /\ lastOp = "none"

----
Commit ==
  /\ lastOp' = "commit"
  /\ index' = -1
  /\ hasMidCaret' = FALSE
  /\ \/ wordCount' = wordCount
     \/ /\ wordCount < MaxCount
        /\ wordCount' = wordCount + 1

\* Host/session mid-buffer after go-to / word move (not a select)
SetMidCaret ==
  /\ hasMidCaret' = TRUE
  /\ lastOp' = "setMid"
  /\ UNCHANGED <<wordCount, index>>

ClearMidCaret ==
  /\ hasMidCaret' = FALSE
  /\ lastOp' = "clearMid"
  /\ UNCHANGED <<wordCount, index>>

\* Select next from end with no mid caret → keyboard fallback; index stays -1
NextWordKeyboard ==
  /\ wordCount >= 1
  /\ index = -1
  /\ ~hasMidCaret
  /\ lastOp' = "keyboard"
  /\ UNCHANGED <<wordCount, index, hasMidCaret>>

\* Select next from mid caret: arm a word (0..wordCount-1); selection starts walk
NextWordFromMid ==
  /\ wordCount >= 1
  /\ index = -1
  /\ hasMidCaret
  /\ \E i \in 0..(wordCount - 1):
       /\ index' = i
       /\ lastOp' = "next"
       /\ hasMidCaret' = FALSE   \* armSessionSelection clears sessionCaret
  /\ UNCHANGED wordCount

\* Progressive next while walking
NextWordAdvance ==
  /\ wordCount >= 1
  /\ index >= 0
  /\ index < wordCount - 1
  /\ index' = index + 1
  /\ lastOp' = "next"
  /\ UNCHANGED <<wordCount, hasMidCaret>>

\* Select previous: from end → last word; else step back
PrevWord ==
  /\ wordCount >= 1
  /\ IF index = -1
     THEN /\ index' = wordCount - 1
          /\ lastOp' = "prev"
          /\ UNCHANGED <<wordCount, hasMidCaret>>
     ELSE /\ index > 0
          /\ index' = index - 1
          /\ lastOp' = "prev"
          /\ UNCHANGED <<wordCount, hasMidCaret>>

SelectLast ==
  /\ wordCount >= 1
  /\ index' = wordCount - 1
  /\ lastOp' = "last"
  /\ UNCHANGED <<wordCount, hasMidCaret>>

Next ==
  \/ Commit
  \/ SetMidCaret
  \/ ClearMidCaret
  \/ NextWordKeyboard
  \/ NextWordFromMid
  \/ NextWordAdvance
  \/ PrevWord
  \/ SelectLast

Spec == Init /\ [][Next]_vars

----
\* Keyboard fallback never invents a progressive index
KeyboardKeepsEnd ==
  lastOp = "keyboard" => index = -1

Inv ==
  /\ TypeOK
  /\ IndexInRange
  /\ KeyboardKeepsEnd

BaitInv == ~KeyboardKeepsEnd

StateConstraint == wordCount <= MaxCount

====
