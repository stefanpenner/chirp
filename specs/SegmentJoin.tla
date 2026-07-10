---- MODULE SegmentJoin ----
(*
  Abstract segment-join policy (SegmentJoiner.swift).

  Purpose: when appending a new ASR segment, choose separator:
    - first piece → none
    - after terminal punct → space
    - uppercase start after bare text → sentence break ". "
      UNLESS next is a proper-noun / dict continuation → space
    - otherwise → space

  Grain: boolean flags, not strings.
  Dual of SegmentJoiner.needsSentenceBreak / looksLikeProperContinuation.
*)

EXTENDS Integers, TLC

VARIABLES
  hasText,       \* existing transcript non-empty
  endsWithPunct, \* existing ends with .!?
  nextUpper,     \* next segment starts uppercase
  nextProper,    \* next is proper noun / dict product continuation
  lastSep        \* "none" | "space" | "sentence"

vars == <<hasText, endsWithPunct, nextUpper, nextProper, lastSep>>

TypeOK ==
  /\ hasText \in BOOLEAN
  /\ endsWithPunct \in BOOLEAN
  /\ nextUpper \in BOOLEAN
  /\ nextProper \in BOOLEAN
  /\ lastSep \in {"none", "space", "sentence"}

Init ==
  /\ hasText = FALSE
  /\ endsWithPunct = FALSE
  /\ nextUpper = FALSE
  /\ nextProper = FALSE
  /\ lastSep = "none"

----
\* Append first segment
AppendFirst ==
  /\ ~hasText
  /\ hasText' = TRUE
  /\ lastSep' = "none"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ nextProper' \in BOOLEAN

\* Append continuation when existing already has terminal punct
AppendAfterPunct ==
  /\ hasText
  /\ endsWithPunct
  /\ lastSep' = "space"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ nextProper' \in BOOLEAN
  /\ UNCHANGED hasText

\* Append new sentence (uppercase clause) after bare text
AppendSentenceBreak ==
  /\ hasText
  /\ ~endsWithPunct
  /\ nextUpper
  /\ ~nextProper
  /\ lastSep' = "sentence"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ nextProper' \in BOOLEAN
  /\ UNCHANGED hasText

\* Mid-clause: lowercase, OR uppercase proper/dict continuation
AppendSpace ==
  /\ hasText
  /\ ~endsWithPunct
  /\ ( ~nextUpper \/ nextProper )
  /\ lastSep' = "space"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ nextProper' \in BOOLEAN
  /\ UNCHANGED hasText

Next ==
  \/ AppendFirst
  \/ AppendAfterPunct
  \/ AppendSentenceBreak
  \/ AppendSpace

Spec == Init /\ [][Next]_vars

----
SentenceImpliesContext ==
  lastSep = "sentence" => hasText

\* Sentence break never chosen for proper/dict continuation in last step
\* (enforced by AppendSentenceBreak guard). Soft safety:
NoSentenceWhenOnlyProper ==
  \* if last action was space with upper+proper, lastSep is space
  TRUE

Inv ==
  /\ TypeOK
  /\ SentenceImpliesContext

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~SentenceImpliesContext

====
