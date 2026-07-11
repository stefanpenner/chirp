---- MODULE MoveN ----
(*
  Counted cursor move N words/characters must not mutate the session buffer.

  Dual of:
    DictationCommand.movePreviousWords / moveNextWords
    DictationCommand.movePreviousCharacters / moveNextCharacters
    AppState.performMoveWords / performMoveCharacters
    (TextInserter.moveWord × N or moveBackward/Forward; transcribedText unchanged)

  Grain: bufferLen only (0..4). Move-N actions leave bufferLen unchanged.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  prevBufferLen,  \* bufferLen before last move (for inv)
  lastOp,         \* "none" | "commit" | "move"
  lastN           \* last move count (1..MaxN)

vars == <<bufferLen, prevBufferLen, lastOp, lastN>>

MaxLen == 4
MaxN == 3

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "move"}
  /\ lastN \in 0..MaxN

Init ==
  /\ bufferLen = 0
  /\ prevBufferLen = 0
  /\ lastOp = "none"
  /\ lastN = 0

----
\* Normal dictation commit grows the buffer
Commit(n) ==
  /\ n \in 1..MaxLen
  /\ bufferLen + n <= MaxLen
  /\ bufferLen' = bufferLen + n
  /\ lastOp' = "commit"
  /\ lastN' = 0
  /\ UNCHANGED prevBufferLen

\* Move N units (words or characters) — keyboard only; session buffer unchanged
MoveN ==
  /\ \E n \in 1..MaxN:
       /\ prevBufferLen' = bufferLen
       /\ lastOp' = "move"
       /\ lastN' = n
       /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ MoveN

Spec == Init /\ [][Next]_vars

----
\* After any move-N op, buffer length equals pre-move length
MovePreservesBuffer ==
  lastOp = "move" => bufferLen = prevBufferLen

\* Move count is always positive when lastOp is move
MoveCountPositive ==
  lastOp = "move" => lastN >= 1

Inv ==
  /\ TypeOK
  /\ MovePreservesBuffer
  /\ MoveCountPositive

\* Bait: claim move-N may change the buffer (must FAIL under TLC)
BaitInv == ~MovePreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
