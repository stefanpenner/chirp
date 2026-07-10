---- MODULE SegmentJoin ----
(*
  Abstract segment-join policy (SegmentJoiner.swift).

  Purpose: when appending a new ASR segment, choose separator:
    - first piece → none
    - after terminal punct → space
    - uppercase start after bare text → sentence break ". "
    - otherwise → space

  Grain: boolean flags, not strings.
*)

EXTENDS Integers, TLC

VARIABLES
  hasText,       \* existing transcript non-empty
  endsWithPunct, \* existing ends with .!?
  nextUpper,     \* next segment starts uppercase
  lastSep        \* "none" | "space" | "sentence"

vars == <<hasText, endsWithPunct, nextUpper, lastSep>>

TypeOK ==
  /\ hasText \in BOOLEAN
  /\ endsWithPunct \in BOOLEAN
  /\ nextUpper \in BOOLEAN
  /\ lastSep \in {"none", "space", "sentence"}

Init ==
  /\ hasText = FALSE
  /\ endsWithPunct = FALSE
  /\ nextUpper = FALSE
  /\ lastSep = "none"

----
\* Append first segment
AppendFirst ==
  /\ ~hasText
  /\ hasText' = TRUE
  /\ lastSep' = "none"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN

\* Append continuation when existing already has terminal punct
AppendAfterPunct ==
  /\ hasText
  /\ endsWithPunct
  /\ lastSep' = "space"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ UNCHANGED hasText

\* Append new sentence (uppercase) after bare text
AppendSentenceBreak ==
  /\ hasText
  /\ ~endsWithPunct
  /\ nextUpper
  /\ lastSep' = "sentence"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ UNCHANGED hasText

\* Append lowercase/mid-clause continuation
AppendSpace ==
  /\ hasText
  /\ ~endsWithPunct
  /\ ~nextUpper
  /\ lastSep' = "space"
  /\ endsWithPunct' \in BOOLEAN
  /\ nextUpper' \in BOOLEAN
  /\ UNCHANGED hasText

Next ==
  \/ AppendFirst
  \/ AppendAfterPunct
  \/ AppendSentenceBreak
  \/ AppendSpace

Spec == Init /\ [][Next]_vars

----
\* First append never uses a separator
FirstIsNone ==
  (~hasText) => lastSep = "none"  \* only holds in Init; after first, hasText
  \/ hasText

\* Sentence break only when we had text, no punct, and next was upper
\* Enforced by action guards. Safety:
SentenceImpliesContext ==
  lastSep = "sentence" => hasText

Inv ==
  /\ TypeOK
  /\ SentenceImpliesContext

====
