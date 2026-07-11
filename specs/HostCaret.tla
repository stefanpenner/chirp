---- MODULE HostCaret ----
(*
  Host keystroke "from" offset for relative moves.

  Dual of SessionCaretDecision.hostFrom / moveDelta and
  AppState.moveToSessionOffset / moveToParagraphOffset / moveToLineOffset.

  Before this dual, host always assumed "from = end" when unit nav was nil,
  so a second go-to after the first (or go-to after word move) desynced host
  from sessionCaret.

  Grain: abstract lengths. caret = -1 means end (append mode).
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,       \* session transcript length
  caret,         \* abstract session caret; -1 = end
  hostPos,       \* last known host caret (always 0..textLen; end = textLen)
  lastOp         \* "none" | "goTo" | "goAfter" | "wordLeft" | "reset"

vars == <<textLen, caret, hostPos, lastOp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ caret \in -1..MaxLen
  /\ hostPos \in 0..MaxLen
  /\ lastOp \in {"none", "goTo", "goAfter", "wordLeft", "reset"}
  /\ caret = -1 \/ (caret >= 0 /\ caret <= textLen)
  /\ hostPos <= textLen

\* Dual of SessionCaretDecision.hostFrom
HostFrom(c, bufLen) ==
  IF c = -1 THEN bufLen ELSE c

Init ==
  /\ textLen = 5
  /\ caret = -1
  /\ hostPos = 5
  /\ lastOp = "none"

----
\* Go to absolute offset (match start). Host moves from HostFrom(caret).
GoTo(start) ==
  /\ start \in 0..textLen
  /\ LET from == HostFrom(caret, textLen)
         delta == start - from
     IN /\ hostPos' = start
        /\ caret' = IF start >= textLen THEN -1 ELSE start
        /\ lastOp' = "goTo"
        /\ UNCHANGED textLen

\* Go after match end
GoAfter(endPos) ==
  /\ endPos \in 0..textLen
  /\ LET from == HostFrom(caret, textLen)
     IN /\ hostPos' = endPos
        /\ caret' = IF endPos >= textLen THEN -1 ELSE endPos
        /\ lastOp' = "goAfter"
        /\ UNCHANGED textLen

\* Word left: host already moved; sessionCaret tracks
WordLeft ==
  /\ caret = -1 \/ caret > 0
  /\ LET newC == IF caret = -1 THEN textLen - 1 ELSE caret - 1
     IN /\ newC >= 0
        /\ caret' = newC
        /\ hostPos' = newC
        /\ lastOp' = "wordLeft"
        /\ UNCHANGED textLen

\* New session
Reset ==
  /\ textLen' = 5
  /\ caret' = -1
  /\ hostPos' = 5
  /\ lastOp' = "reset"

Next ==
  \/ \E s \in 0..textLen: GoTo(s)
  \/ \E e \in 0..textLen: GoAfter(e)
  \/ WordLeft
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* Host always tracks caret (end mode => host at textLen)
HostTracksCaret ==
  IF caret = -1
  THEN hostPos = textLen
  ELSE hostPos = caret

Inv ==
  /\ TypeOK
  /\ HostTracksCaret

BaitInv == ~HostTracksCaret

StateConstraint == textLen <= MaxLen

====
