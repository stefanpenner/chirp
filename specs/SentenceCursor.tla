---- MODULE SentenceCursor ----
(*
  Progressive sentence navigation index (SessionCaret design dual).

  Models a session-relative cursor over sentence starts so repeated
  "next sentence" / "previous sentence" can walk 2nd, 3rd, … sentences.

  Dual of:
    AppState.sentenceNavIndex: Int?   \* nil = at end (dual of index = -1)
    DictationCommand move/select/delete next + previous sentence progressive path
    TranscriptSelection.sentenceRanges

  MoveSentence.tla still covers bufferLen invariance for moves.

  Grain:
    sentenceCount \in 0..MaxCount
    index = -1 means caret at end of buffer
    index \in 0..(sentenceCount-1) means caret at start of that sentence (0-based)
*)

EXTENDS Integers, TLC

VARIABLES
  sentenceCount,  \* number of sentences in the session buffer
  index,          \* -1 = end; else 0-based sentence under caret
  lastOp          \* "none" | "commit" | "next" | "prev"

vars == <<sentenceCount, index, lastOp>>

MaxCount == 4

TypeOK ==
  /\ sentenceCount \in 0..MaxCount
  /\ index \in -1..MaxCount
  /\ lastOp \in {"none", "commit", "next", "prev"}

\* index at end (-1) or a valid in-range sentence start
IndexInRange ==
  \/ index = -1
  \/ /\ index >= 0
     /\ index < sentenceCount

Init ==
  /\ sentenceCount = 0
  /\ index = -1
  /\ lastOp = "none"

----
\* Dictation commit: abstract +0..1 sentence; always reset caret to end
Commit ==
  /\ lastOp' = "commit"
  /\ index' = -1
  /\ \/ sentenceCount' = sentenceCount
     \/ /\ sentenceCount < MaxCount
        /\ sentenceCount' = sentenceCount + 1

\* Progressive next: first next from end lands on sentence 1 (second sentence);
\* further next advances while not on the last sentence.
NextSentence ==
  /\ sentenceCount >= 2
  /\ IF index = -1
     THEN index' = 1
     ELSE /\ index < sentenceCount - 1
          /\ index' = index + 1
  /\ lastOp' = "next"
  /\ UNCHANGED sentenceCount

\* Progressive prev: from end land on last sentence; else step back while > 0
PrevSentence ==
  /\ sentenceCount >= 1
  /\ IF index = -1
     THEN index' = sentenceCount - 1
     ELSE /\ index > 0
          /\ index' = index - 1
  /\ lastOp' = "prev"
  /\ UNCHANGED sentenceCount

Next ==
  \/ Commit
  \/ NextSentence
  \/ PrevSentence

Spec == Init /\ [][Next]_vars

----
\* After next from end, first hop is sentence 1 when count >= 2
\* (encoded in NextSentence; safety form for reachable post-states)
NextLandsInRange ==
  lastOp = "next" => (index >= 1 /\ index < sentenceCount)

PrevLandsInRange ==
  lastOp = "prev" => (index >= 0 /\ index < sentenceCount)

\* Commit always leaves caret at end
CommitResetsToEnd ==
  lastOp = "commit" => index = -1

Inv ==
  /\ TypeOK
  /\ IndexInRange
  /\ NextLandsInRange
  /\ PrevLandsInRange
  /\ CommitResetsToEnd

\* Bait: claim index can leave the legal range (must FAIL under TLC)
BaitInv == ~IndexInRange

StateConstraint == sentenceCount <= MaxCount

====
