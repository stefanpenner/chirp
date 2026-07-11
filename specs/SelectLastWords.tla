---- MODULE SelectLastWords ----
(*
  Select last N trailing words leaves session bufferLen unchanged.

  Dual of:
    DictationCommand.selectLastWords(count)
    AppState.performSelectLastWords
    TranscriptSelection.lastWords (span only; no buffer mutate)

  Grain: bufferLen / wordCount abstract (0..MaxLen). Select leaves bufferLen fixed.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  wordCount,      \* whitespace-delimited words in buffer
  prevBufferLen,  \* bufferLen before last select
  lastOp,         \* "none" | "commit" | "selectLastN"
  lastN           \* N requested on last select (0 = none)

vars == <<bufferLen, wordCount, prevBufferLen, lastOp, lastN>>

MaxLen == 5

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ wordCount \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "selectLastN"}
  /\ lastN \in 0..MaxLen
  /\ wordCount <= bufferLen

Init ==
  /\ bufferLen = 0
  /\ wordCount = 0
  /\ prevBufferLen = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
Commit ==
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ prevBufferLen' = bufferLen
  /\ \/ /\ bufferLen < MaxLen
        /\ bufferLen' = bufferLen + 1
        /\ wordCount' = wordCount + 1
     \/ /\ bufferLen' = bufferLen
        /\ wordCount' = wordCount

\* Select last N words (N ≥ 2); clamp N to wordCount; buffer unchanged
SelectLastN ==
  /\ wordCount >= 1
  /\ \E n \in 1..MaxLen:
       /\ lastN' = n
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "selectLastN"
       /\ UNCHANGED <<bufferLen, wordCount>>

Next ==
  \/ Commit
  \/ SelectLastN

Spec == Init /\ [][Next]_vars

----
SelectPreservesBuffer ==
  lastOp = "selectLastN" => bufferLen = prevBufferLen

\* N is always positive on select
SelectCountPositive ==
  lastOp = "selectLastN" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer
  /\ SelectCountPositive

BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
