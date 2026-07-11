---- MODULE MoveSentence ----
(*
  Move previous / next sentence must not mutate the session buffer.

  Dual of:
    DictationCommand.moveToPreviousSentence / moveToNextSentence
    AppState.performMoveToPreviousSentence / performMoveToNextSentence
    (TextInserter moveBackward/moveForward only; transcribedText unchanged)

  Product behavior (session-relative, no caret tracking):
    - previous: ← × lastSentence length (assumes caret at end)
    - next: from end, jump to start of second sentence
      (← full buffer, → past first sentence); single-sentence no-op
    - progressive 3rd+ sentence: see SentenceCursor.tla (sentenceNavIndex dual)

  Grain: bufferLen only (0..4). Move-sentence actions leave bufferLen unchanged.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  prevBufferLen,  \* bufferLen before last move (for inv)
  lastOp          \* "none" | "commit" | "move"

vars == <<bufferLen, prevBufferLen, lastOp>>

MaxLen == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "move"}

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

\* Move previous sentence (← × n) — keyboard only; session buffer unchanged
MovePreviousSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "move"
  /\ UNCHANGED bufferLen

\* Move next sentence (session-relative second-sentence jump) — buffer unchanged
MoveNextSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "move"
  /\ UNCHANGED bufferLen

\* Generic move-sentence (either direction)
MoveSentence ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "move"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MovePreviousSentence
  \/ MoveNextSentence
  \/ MoveSentence

Spec == Init /\ [][Next]_vars

----
\* After any move-sentence op, buffer length equals pre-move length
MovePreservesBuffer ==
  lastOp = "move" => bufferLen = prevBufferLen

Inv ==
  /\ TypeOK
  /\ MovePreservesBuffer

\* Bait: claim move-sentence may change the buffer (must FAIL under TLC)
BaitInv == ~MovePreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
