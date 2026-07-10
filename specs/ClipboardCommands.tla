---- MODULE ClipboardCommands ----
(*
  Spoken copy/paste against session transcript + system clipboard.

  Dual: DictationCommand.copyThat / pasteThat + AppState handlers.
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  clipLen,       \* clipboard length
  lastOp         \* "none" | "copy" | "paste"

vars == <<textLen, clipLen, lastOp>>

MaxLen == 6

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ clipLen \in 0..MaxLen
  /\ lastOp \in {"none", "copy", "paste"}

Init ==
  /\ textLen = 0
  /\ clipLen = 0
  /\ lastOp = "none"

Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastOp' = "none"  \* further edits invalidate "just copied" mirror
  /\ UNCHANGED clipLen

CopyThat ==
  /\ textLen > 0
  /\ clipLen' = textLen
  /\ lastOp' = "copy"
  /\ UNCHANGED textLen

PasteThat ==
  /\ clipLen > 0
  /\ textLen + clipLen <= MaxLen
  /\ textLen' = textLen + clipLen
  /\ lastOp' = "paste"
  /\ UNCHANGED clipLen

CopyEmpty ==
  /\ textLen = 0
  /\ UNCHANGED vars

PasteEmpty ==
  /\ clipLen = 0
  /\ UNCHANGED vars

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ CopyThat
  \/ PasteThat
  \/ CopyEmpty
  \/ PasteEmpty

Spec == Init /\ [][Next]_vars

\* After copy, clipboard mirrors transcript length
CopyMirrors ==
  lastOp = "copy" => clipLen = textLen

Inv ==
  /\ TypeOK
  /\ CopyMirrors

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~CopyMirrors

StateConstraint == textLen <= MaxLen

====
