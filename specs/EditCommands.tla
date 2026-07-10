---- MODULE EditCommands ----
(*
  Spoken edit commands over a session transcript.

  Commands:
    Commit(n)       — append n characters
    Scratch         — undo last commit (lastTyped)
    DeleteLastWord  — remove last word (abstract: min(lastTyped, 1) for grain)
    ClearAll        — wipe transcript

  Pure selection commands (SelectThat / SelectLastWord / SelectAll) are
  keyboard-only in the focused app: they do not change textLen/lastTyped,
  so they are omitted from this length model (see DictationCommandTests).

  Grain: lengths only (not word strings). DeleteLastWord modeled as removing
  one unit when text non-empty (abstract word).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,
  lastTyped

vars == <<textLen, lastTyped>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ lastTyped \in 0..MaxLen
  /\ lastTyped <= textLen

Init ==
  /\ textLen = 0
  /\ lastTyped = 0

Commit(n) ==
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastTyped' = n

Scratch ==
  /\ lastTyped > 0
  /\ textLen' = textLen - lastTyped
  /\ lastTyped' = 0

DeleteLastWord ==
  /\ textLen > 0
  /\ textLen' = textLen - 1
  /\ lastTyped' = 0

ClearAll ==
  /\ textLen > 0
  /\ textLen' = 0
  /\ lastTyped' = 0

\* No-ops when empty
ScratchEmpty ==
  /\ lastTyped = 0
  /\ UNCHANGED vars

ClearEmpty ==
  /\ textLen = 0
  /\ UNCHANGED vars

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ Scratch
  \/ ScratchEmpty
  \/ DeleteLastWord
  \/ ClearAll
  \/ ClearEmpty

Spec == Init /\ [][Next]_vars

\* Scratch / delete never leave lastTyped beyond remaining text
LastTypedWithinText == lastTyped <= textLen

Inv ==
  /\ TypeOK
  /\ LastTypedWithinText

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~LastTypedWithinText

StateConstraint == textLen <= MaxLen

====
