---- MODULE TranscriptSelection ----
(*
  Abstract length bounds for last-sentence / last-paragraph selection.

  Dual of TranscriptSelection.lastSentence / lastParagraph
  (DictationCommand.swift) + AppState.performSelectLastSentence/Paragraph.

  Pure size model only: last segment lengths never exceed total buffer.
  Empty buffer => both last lengths are 0.
*)

EXTENDS Integers, TLC

VARIABLES
  totalLen,         \* abstract buffer character count
  lastSentenceLen,  \* length of trailing sentence segment
  lastParaLen       \* length of trailing paragraph segment

vars == <<totalLen, lastSentenceLen, lastParaLen>>

MaxChunk == 3
MaxTotal == 9

TypeOK ==
  /\ totalLen \in 0..MaxTotal
  /\ lastSentenceLen \in 0..MaxTotal
  /\ lastParaLen \in 0..MaxTotal

Init ==
  /\ totalLen = 0
  /\ lastSentenceLen = 0
  /\ lastParaLen = 0

----
\* Grow buffer without a break (extends last sentence + last paragraph)
AppendChunk(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = lastSentenceLen + n
  /\ lastParaLen' = lastParaLen + n

\* Sentence break then n chars of new sentence content (same paragraph)
AppendSentence(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = n
  /\ lastParaLen' = lastParaLen + n

\* Paragraph break then n chars (new sentence + new paragraph)
AppendParagraph(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = n
  /\ lastParaLen' = n

\* Clear buffer (new session / scratch all)
Clear ==
  /\ totalLen > 0
  /\ totalLen' = 0
  /\ lastSentenceLen' = 0
  /\ lastParaLen' = 0

Next ==
  \/ \E n \in 1..MaxChunk: AppendChunk(n)
  \/ \E n \in 1..MaxChunk: AppendSentence(n)
  \/ \E n \in 1..MaxChunk: AppendParagraph(n)
  \/ Clear

Spec == Init /\ [][Next]_vars

----
\* Last segments are suffixes: lengths never exceed total
LastWithinTotal ==
  /\ lastSentenceLen <= totalLen
  /\ lastParaLen <= totalLen

\* Empty buffer has no selectable trailing content
EmptyImpliesZero ==
  totalLen = 0 => (lastSentenceLen = 0 /\ lastParaLen = 0)

\* After a paragraph break, last sentence is contained in last paragraph
\* (AppendParagraph sets both to n; AppendSentence grows para by n)
SentenceWithinPara ==
  lastSentenceLen <= lastParaLen

Inv ==
  /\ TypeOK
  /\ LastWithinTotal
  /\ EmptyImpliesZero
  /\ SentenceWithinPara

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~LastWithinTotal

====
