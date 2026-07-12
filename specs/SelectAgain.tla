---- MODULE SelectAgain ----
(*
  Dragon "select again" / "select next occurrence": walk occurrences of a phrase.

  Dual of:
    PhraseReplaceDecision.findLastRange(before:) / findFirstRange(after:)
    AppState.performSelectAgain / performSelectNextOccurrence

  Seed (SelectPhrase): select X, select that (last stack delta), or select last
  word(s) — all call rememberSelectSearch so select again has a target.

  Grain: abstract count of matches (1..MaxMatches). cursor is 0-based index
  into that list (rightmost = last occurrence = first select). No buffer text.
*)

EXTENDS Integers, TLC

CONSTANTS MaxMatches

VARIABLES
  nMatches,  \* number of occurrences of the search phrase
  cursor,    \* active match index; -1 = none
  lastOp     \* "none" | "select" | "again" | "next" | "miss"

vars == <<nMatches, cursor, lastOp>>

TypeOK ==
  /\ nMatches \in 0..MaxMatches
  /\ cursor \in -1..(MaxMatches - 1)
  /\ lastOp \in {"none", "select", "again", "next", "miss"}
  /\ (nMatches = 0 => cursor = -1)
  /\ (cursor >= 0 => cursor < nMatches)

Init ==
  /\ nMatches = 0
  /\ cursor = -1
  /\ lastOp = "none"

----
\* First "select X": land on rightmost match (index n-1)
SelectPhrase(n) ==
  /\ n \in 1..MaxMatches
  /\ nMatches' = n
  /\ cursor' = n - 1
  /\ lastOp' = "select"

\* Select again: walk left (earlier occurrence)
SelectAgain ==
  /\ nMatches > 0
  /\ cursor >= 0
  /\ IF cursor = 0
     THEN /\ UNCHANGED nMatches
          /\ UNCHANGED cursor
          /\ lastOp' = "miss"
     ELSE /\ UNCHANGED nMatches
          /\ cursor' = cursor - 1
          /\ lastOp' = "again"

\* Select next occurrence: walk right
SelectNext ==
  /\ nMatches > 0
  /\ cursor >= 0
  /\ IF cursor + 1 >= nMatches
     THEN /\ UNCHANGED nMatches
          /\ UNCHANGED cursor
          /\ lastOp' = "miss"
     ELSE /\ UNCHANGED nMatches
          /\ cursor' = cursor + 1
          /\ lastOp' = "next"

Reset ==
  /\ nMatches' = 0
  /\ cursor' = -1
  /\ lastOp' = "none"

Next ==
  \/ \E n \in 1..MaxMatches: SelectPhrase(n)
  \/ SelectAgain
  \/ SelectNext
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* After a successful again/next/select, cursor is a real match
CursorInRange ==
  lastOp \in {"select", "again", "next"} =>
    /\ cursor >= 0
    /\ cursor < nMatches

Inv ==
  /\ TypeOK
  /\ CursorInRange

BaitInv == ~CursorInRange

StateConstraint == nMatches <= MaxMatches

====
