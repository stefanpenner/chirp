---- MODULE WordSelect ----
(*
  Select next/previous word must not mutate the session buffer.

  Dual of:
    DictationCommand.selectNextWord / selectPreviousWord
    AppState.performSelectWord
    Previous (session end): trailing lastWords + arm sessionSelection
    Next: TextInserter.selectWord keyboard only
    Both leave transcribedText / bufferLen unchanged until content type-over.

  Grain: bufferLen only (0..4). Select-word actions leave bufferLen unchanged.
  Arming is modeled as lastOp = "select" without growing buffer (SelectionCommit
  handles the subsequent type-over peel).
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

\* Select next word (⇧⌥→) — keyboard only; session buffer unchanged
SelectNextWord ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

\* Select previous word — session trailing arm; buffer unchanged
SelectPreviousWord ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

\* Generic select-word (either direction)
SelectWord ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "select"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ SelectNextWord
  \/ SelectPreviousWord
  \/ SelectWord

Spec == Init /\ [][Next]_vars

----
\* After any select-word op, buffer length equals pre-select length
SelectPreservesBuffer ==
  lastOp = "select" => bufferLen = prevBufferLen

Inv ==
  /\ TypeOK
  /\ SelectPreservesBuffer

\* Bait: claim select-word may change the buffer (must FAIL under TLC)
BaitInv == ~SelectPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
