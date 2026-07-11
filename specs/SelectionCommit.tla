---- MODULE SelectionCommit ----
(*
  Selection → re-dictate: splice selected range (trailing or middle),
  then insert replacement so session buffer stays dual of host type-over.

  Dual of:
    SelectionCommitDecision.isInRange / bufferAfterRangeReplace / isTrailing
    AppState.sessionSelection + content path (.none)

  Grain: textLen, selStart, selLen, typedToApp.
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,          \* session transcript length
  selStart,         \* selection start offset (-1 = none)
  selLen,           \* selection length (0 = none)
  lastTyped,        \* size of last content delta
  typedToApp        \* characters accounted in host (mirrors textLen)

vars == <<textLen, selStart, selLen, lastTyped, typedToApp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ selStart \in -1..MaxLen
  /\ selLen \in 0..MaxLen
  /\ lastTyped \in 0..MaxLen
  /\ typedToApp \in 0..MaxLen
  /\ lastTyped <= textLen
  /\ typedToApp = textLen
  /\ \/ /\ selStart = -1
        /\ selLen = 0
     \/ /\ selStart >= 0
        /\ selLen > 0
        /\ selStart + selLen <= textLen

Init ==
  /\ textLen = 0
  /\ selStart = -1
  /\ selLen = 0
  /\ lastTyped = 0
  /\ typedToApp = 0

----
\* Normal content append (no selection)
Commit(n) ==
  /\ selLen = 0
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastTyped' = n
  /\ typedToApp' = typedToApp + n
  /\ UNCHANGED <<selStart, selLen>>

\* Select any in-range window [start, start+len)
SelectRange(start, len) ==
  /\ start \in 0..MaxLen
  /\ len \in 1..MaxLen
  /\ start + len <= textLen
  /\ selStart' = start
  /\ selLen' = len
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

\* Unselect / format collapse
ClearSelection ==
  /\ selLen > 0
  /\ selStart' = -1
  /\ selLen' = 0
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

\* Content while selection active: splice window with n (host type-over)
ReplaceCommit(n) ==
  /\ selLen > 0
  /\ selStart >= 0
  /\ n \in 1..MaxLen
  /\ LET base == textLen - selLen
     IN /\ base + n <= MaxLen
        /\ textLen' = base + n
        /\ typedToApp' = base + n
        /\ lastTyped' = n
        /\ selStart' = -1
        /\ selLen' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E start \in 0..MaxLen:
       \E len \in 1..MaxLen: SelectRange(start, len)
  \/ ClearSelection
  \/ \E n \in 1..MaxLen: ReplaceCommit(n)

Spec == Init /\ [][Next]_vars

----
TypedMatchesText == typedToApp = textLen

SelInRange ==
  \/ selLen = 0
  \/ /\ selStart >= 0
     /\ selStart + selLen <= textLen

Inv ==
  /\ TypeOK
  /\ TypedMatchesText
  /\ SelInRange

BaitInv == ~TypedMatchesText

StateConstraint == textLen <= MaxLen

====
