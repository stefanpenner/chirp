---- MODULE TranscriptSelection ----
(*
  Abstract length bounds for last-sentence / last-paragraph / last-line selection.

  Dual of TranscriptSelection.lastSentence / lastParagraph / lastLine
  (DictationCommand.swift) + AppState.performSelectLastSentence/Paragraph/Line.

  Pure size model only: last segment lengths never exceed total buffer.
  Empty buffer => all last lengths are 0.
*)

EXTENDS Integers, TLC

VARIABLES
  totalLen,         \* abstract buffer character count
  lastSentenceLen,  \* length of trailing sentence segment
  lastParaLen,      \* length of trailing paragraph segment
  lastLineLen       \* length of trailing line segment (after last \n)

vars == <<totalLen, lastSentenceLen, lastParaLen, lastLineLen>>

MaxChunk == 3
MaxTotal == 9

TypeOK ==
  /\ totalLen \in 0..MaxTotal
  /\ lastSentenceLen \in 0..MaxTotal
  /\ lastParaLen \in 0..MaxTotal
  /\ lastLineLen \in 0..MaxTotal

Init ==
  /\ totalLen = 0
  /\ lastSentenceLen = 0
  /\ lastParaLen = 0
  /\ lastLineLen = 0

----
\* Grow buffer without a break (extends last sentence + last paragraph + last line)
AppendChunk(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = lastSentenceLen + n
  /\ lastParaLen' = lastParaLen + n
  /\ lastLineLen' = lastLineLen + n

\* Sentence break then n chars of new sentence content (same paragraph + line)
AppendSentence(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = n
  /\ lastParaLen' = lastParaLen + n
  /\ lastLineLen' = lastLineLen + n

\* Soft line break (\n) then n chars — new line within same paragraph
AppendLine(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastLineLen' = n
  /\ lastSentenceLen' = n
  /\ lastParaLen' = lastParaLen + n

\* Paragraph break then n chars (new sentence + new line + new paragraph)
AppendParagraph(n) ==
  /\ n \in 1..MaxChunk
  /\ totalLen + n <= MaxTotal
  /\ totalLen' = totalLen + n
  /\ lastSentenceLen' = n
  /\ lastParaLen' = n
  /\ lastLineLen' = n

\* Clear buffer (new session / scratch all)
Clear ==
  /\ totalLen > 0
  /\ totalLen' = 0
  /\ lastSentenceLen' = 0
  /\ lastParaLen' = 0
  /\ lastLineLen' = 0

Next ==
  \/ \E n \in 1..MaxChunk: AppendChunk(n)
  \/ \E n \in 1..MaxChunk: AppendSentence(n)
  \/ \E n \in 1..MaxChunk: AppendLine(n)
  \/ \E n \in 1..MaxChunk: AppendParagraph(n)
  \/ Clear

Spec == Init /\ [][Next]_vars

----
\* Last segments are suffixes: lengths never exceed total
LastWithinTotal ==
  /\ lastSentenceLen <= totalLen
  /\ lastParaLen <= totalLen
  /\ lastLineLen <= totalLen

\* Empty buffer has no selectable trailing content
EmptyImpliesZero ==
  totalLen = 0 =>
    (lastSentenceLen = 0 /\ lastParaLen = 0 /\ lastLineLen = 0)

\* After a paragraph break, last sentence is contained in last paragraph
\* (AppendParagraph sets both to n; AppendSentence grows para by n)
SentenceWithinPara ==
  lastSentenceLen <= lastParaLen

\* Line is a suffix of the current paragraph (soft \n stays inside para;
\* hard para break resets both)
LineWithinPara ==
  lastLineLen <= lastParaLen

Inv ==
  /\ TypeOK
  /\ LastWithinTotal
  /\ EmptyImpliesZero
  /\ SentenceWithinPara
  /\ LineWithinPara

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~LastWithinTotal

====
