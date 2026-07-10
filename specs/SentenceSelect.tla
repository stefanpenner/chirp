---- MODULE SentenceSelect ----
(*
  Select first / last / next sentence must not mutate the session buffer.

  Dual of:
    DictationCommand.selectLastSentence
    AppState.performSelectLastSentence
    (TextInserter.selectBackward only; transcribedText unchanged)
    plus first/next sentence selection (keyboard or buffer ops) under the
    same contract: selection does not change session bufferLen.

  Grain: bufferLen only (0..4). Select-sentence actions leave bufferLen unchanged.
  Delete last sentence is covered by DeleteSegment (not modeled here).
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  prevBufferLen,  \* bufferLen before last select (for inv)
  lastOp          \* "none" | "commit" | "select"

vars == <<bufferLen, prevBufferLen, lastOp>>

MaxLen == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "select"}

Init ==
  /\ bufferLen = 0
  /\ prevBufferLen = 0
  /\ lastOp = "none"

----
\* Normal dictation commit grows the buffer
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastOp' = "commit"
  /\ UNCHANGED prevBufferLen

\* Select last sentence — selectBackward only; session buffer unchanged
SelectLastSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

\* Select first sentence — same contract (buffer-relative selection)
SelectFirstSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

\* Select next sentence — keyboard or buffer select; session buffer unchanged
SelectNextSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

\* Generic select-sentence (any of the above)
SelectSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectLastSentence
  \/ SelectFirstSentence
  \/ SelectNextSentence
  \/ SelectSentence

Spec == Init /\ [][Next]_vars

----
\* After any select-sentence op, buffer length equals pre-select length
SelectPreservesBuffer ==
  lastOp = "select" => bufferLen = prevBufferLen

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer

\* Bait: claim select-sentence may change the buffer (must FAIL under TLC)
BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
