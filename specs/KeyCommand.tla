---- MODULE KeyCommand ----
(*
  Keyboard-only dictation commands must not mutate the session buffer.

  Dual of:
    DictationCommand.pressBackspace / pressEscape(count) / pressUndo / pressRedo /
      pressForwardDelete
    AppState.performPressBackspace / performPressEscape / performPressUndo /
      performPressRedo / performPressForwardDelete
    (TextInserter key posts only; transcribedText unchanged)

  Grain: bufferLen only (0..4). Key actions leave bufferLen unchanged.
  Counted Escape N is EscapeN.tla (presses); this module only checks buffer safety.

  Note: spoken "scratch that" is EditStack (session undo), not a key command.
  System Cmd+Z (pressUndo) and Cmd+Shift+Z (pressRedo) share this invariant.
  Forward Delete (0x75) is also keyboard-only (not laptop Delete / Backspace).
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

\* System undo (⌘Z) — keyboard only; session buffer / edit stack unchanged
PressUndo ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

\* System redo (⌘⇧Z) — keyboard only; session buffer / edit stack unchanged
PressRedo ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

\* Forward Delete (0x75) — keyboard only; not laptop Delete / Backspace
PressForwardDelete ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

\* Generic key-only command (backspace, escape, undo, redo, forward delete)
KeyOnly ==
  /\ prevBufferLen' = bufferLen
  /\ lastOp' = "key"
  /\ UNCHANGED bufferLen

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ PressBackspace
  \/ PressEscape
  \/ PressUndo
  \/ PressRedo
  \/ PressForwardDelete
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
