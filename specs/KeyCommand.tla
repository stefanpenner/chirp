---- MODULE KeyCommand ----
(*
  Keyboard-only dictation commands must not mutate the session buffer.

  Dual of:
    DictationCommand.pressBackspace / pressEscape
    AppState.performPressBackspace / performPressEscape
    (TextInserter.deleteBackward / pressEscape only; transcribedText unchanged)

  Grain: bufferLen only (0..4). Key actions leave bufferLen unchanged.

  Note: spoken "scratch that" is EditStack (session undo), not a key command.
  System Cmd+Z (pressUndo) is not product-landed; same invariant if added later.
*)

EXTENDS Integers, TLC

VARIABLES
  bufferLen,      \* session transcript length
  prevBufferLen,  \* bufferLen before last key command (for inv)
  lastOp          \* "none" | "commit" | "key"

vars == <<bufferLen, prevBufferLen, lastOp>>

MaxLen == 4

TypeOK ==
  /\ bufferLen \in 0..MaxLen
  /\ prevBufferLen \in 0..MaxLen
  /\ lastOp \in {"none", "commit", "key"}

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

\* Press Backspace once — keyboard only; session buffer unchanged
PressBackspace ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

\* Press Escape once — keyboard only; does not cancel Chirp session
PressEscape ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

\* Generic key-only command (either backspace or escape)
KeyOnly ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ PressBackspace
  \/ PressEscape
  \/ KeyOnly

Spec == Init /\ [][Next]_vars

----
\* After any key-only op, buffer length equals pre-key length
KeyPreservesBuffer ==
  lastOp = "key" => bufferLen = prevBufferLen

Inv ==
  /\ TypeOK
  /\ KeyPreservesBuffer

\* Bait: claim key commands may change the buffer (must FAIL under TLC)
BaitInv == ~KeyPreservesBuffer

StateConstraint == bufferLen <= MaxLen

====
