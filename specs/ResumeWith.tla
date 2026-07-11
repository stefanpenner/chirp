---- MODULE ResumeWith ----
(*
  Dragon "resume with X": keep text through last match of X; drop the rest.
  Caret ends at end of kept text (append mode for next content).

  Dual of:
    ResumeWithDecision.truncateAfterLastMatch
    AppState.performResumeWith
    PhraseReplaceDecision.findLastRange

  Grain: abstract lengths.
  caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  hasMatch,      \* last find would succeed
  matchEnd,      \* exclusive end offset of match when hasMatch
  caret,         \* -1 = end; else 0..textLen
  lastOp         \* "none" | "commit" | "resume" | "miss" | "insert"

vars == <<textLen, hasMatch, matchEnd, caret, lastOp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ hasMatch \in BOOLEAN
  /\ matchEnd \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ lastOp \in {"none", "commit", "resume", "miss", "insert"}
  /\ hasMatch => (matchEnd > 0 /\ matchEnd <= textLen)
  /\ ~hasMatch => matchEnd = 0
  /\ caret = -1 \/ (caret >= 0 /\ caret <= textLen)

Init ==
  /\ textLen = 0
  /\ hasMatch = FALSE
  /\ matchEnd = 0
  /\ caret = -1
  /\ lastOp = "none"

----
Commit(n) ==
  /\ caret = -1
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ caret' = -1
  /\ lastOp' = "commit"
  /\ \/ /\ hasMatch' = FALSE
        /\ matchEnd' = 0
     \/ /\ hasMatch' = TRUE
        /\ \E e \in 1..textLen':
             matchEnd' = e

\* Truncate to matchEnd; caret at end (-1)
ResumeHit ==
  /\ hasMatch
  /\ matchEnd > 0
  /\ matchEnd <= textLen
  /\ textLen' = matchEnd
  /\ caret' = -1
  /\ lastOp' = "resume"
  /\ hasMatch' = FALSE
  /\ matchEnd' = 0

ResumeMiss ==
  /\ ~hasMatch
  /\ lastOp' = "miss"
  /\ UNCHANGED <<textLen, hasMatch, matchEnd, caret>>

\* After resume, append more content at end
InsertEnd(n) ==
  /\ caret = -1
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ caret' = -1
  /\ lastOp' = "insert"
  /\ hasMatch' = FALSE
  /\ matchEnd' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ ResumeHit
  \/ ResumeMiss
  \/ \E n \in 1..MaxLen: InsertEnd(n)

Spec == Init /\ [][Next]_vars

----
CaretInRange ==
  caret = -1 \/ (caret >= 0 /\ caret <= textLen)

\* Resume leaves caret at end and textLen = former matchEnd (then cleared)
ResumeEndsAtEnd ==
  lastOp = "resume" => caret = -1

Inv ==
  /\ TypeOK
  /\ CaretInRange
  /\ ResumeEndsAtEnd

BaitInv == ~ResumeEndsAtEnd

StateConstraint == textLen <= MaxLen

====
