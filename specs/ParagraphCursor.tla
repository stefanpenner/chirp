---- MODULE ParagraphCursor ----
(*
  Progressive paragraph navigation index (select / move / delete next).

  Models a session-relative cursor over paragraph starts so repeated
  "next paragraph" / "previous paragraph" / "select next" can walk
  2nd, 3rd, … paragraphs.

  Dual of:
    AppState.paragraphNavIndex: Int?   \* nil = at end (dual of index = -1)
    DictationCommand select/move/delete next + previous paragraph progressive path
    TranscriptSelection.paragraphRanges

  Grain:
    paragraphCount \in 0..MaxCount
    index = -1 means caret at end of buffer
    index \in 0..(paragraphCount-1) means paragraph under caret (0-based)
*)

EXTENDS Integers, TLC

VARIABLES
  paragraphCount,  \* number of paragraphs in the session buffer
  index,           \* -1 = end; else 0-based paragraph under caret
  lastOp           \* "none" | "commit" | "next" | "prev" | "delete"

vars == <<paragraphCount, index, lastOp>>

MaxCount == 4

TypeOK ==
  /\ paragraphCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ lastOp \in {"none", "commit", "next", "prev", "delete"}

\* index at end (-1) or a valid in-range paragraph
IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < paragraphCount

Init ==
  /\ paragraphCount = 0
  /\ index = -1
  /\ lastOp = "none"

----
\* Dictation commit: abstract +0..1 paragraph; always reset caret to end
Commit ==
  /\ lastOp' = "commit"
  /\ index' = -1
  /\ \/ paragraphCount' = paragraphCount
     \/ /\ paragraphCount < MaxCount
        /\ paragraphCount' = paragraphCount + 1

\* Progressive next: first next from end lands on paragraph 1 (second);
\* further next advances while not on the last paragraph.
NextParagraph ==
  /\ paragraphCount >= 2
  /\ IF index = -1
     THEN index' = 1
     ELSE /\ index < paragraphCount - 1
          /\ index' = index + 1
  /\ lastOp' = "next"
  /\ UNCHANGED paragraphCount

\* Progressive prev: from end land on last paragraph; else step back while > 0
PrevParagraph ==
  /\ paragraphCount >= 1
  /\ IF index = -1
     THEN index' = paragraphCount - 1
     ELSE /\ index > 0
          /\ index' = index - 1
  /\ lastOp' = "prev"
  /\ UNCHANGED paragraphCount

\* Progressive delete next: remove next paragraph; reset caret to end;
\* count decreases when > 0
DeleteNextParagraph ==
  /\ paragraphCount >= 2
  /\ IF index = -1
     THEN TRUE
     ELSE index < paragraphCount - 1
  /\ lastOp' = "delete"
  /\ index' = -1
  /\ paragraphCount' = paragraphCount - 1

Next ==
  \/ Commit
  \/ NextParagraph
  \/ PrevParagraph
  \/ DeleteNextParagraph

Spec == Init /\ [][Next]_vars

----
NextLandsInRange ==
  lastOp = "next" => (index >= 1 /\ index < paragraphCount)

PrevLandsInRange ==
  lastOp = "prev" => (index >= 0 /\ index < paragraphCount)

\* Commit and delete always leave caret at end
CommitResetsToEnd ==
  lastOp \in {"commit", "delete"} => index = -1

Inv ==
  /\ TypeOK
  /\ IndexInRange
  /\ NextLandsInRange
  /\ PrevLandsInRange
  /\ CommitResetsToEnd

\* Bait: claim index can leave the legal range (must FAIL under TLC)
BaitInv == ~IndexInRange

StateConstraint == paragraphCount <= MaxCount

====
