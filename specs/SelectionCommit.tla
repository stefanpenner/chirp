---- MODULE SelectionCommit ----
(*
  Trailing selection → re-dictate: peel selected suffix, then insert
  replacement so session buffer stays dual of host type-over.

  Dual of:
    SelectionCommitDecision.shouldReplaceSuffix / bufferAfterReplace
    AppState.sessionSelectionSuffix + content path (.none)

  Grain: textLen, selLen, typedToApp. Host type-over replaces selLen
  with n without intermediate delete counting.
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,          \* session transcript length
  selLen,           \* trailing selection length (0 = none)
  lastTyped,        \* size of last content delta
  typedToApp        \* characters accounted in host (mirrors textLen)

vars == <<textLen, selLen, lastTyped, typedToApp>>

MaxLen == 8

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ selLen \in 0..MaxLen
  /\ lastTyped \in 0..MaxLen
  /\ typedToApp \in 0..MaxLen
  /\ selLen <= textLen
  /\ lastTyped <= textLen
  /\ typedToApp = textLen

Init ==
  /\ textLen = 0
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
  /\ UNCHANGED selLen

\* Select trailing suffix of length s (must fit)
SelectTrailing(s) ==
  /\ s \in 1..MaxLen
  /\ s <= textLen
  /\ selLen' = s
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

\* Unselect / format collapse
ClearSelection ==
  /\ selLen > 0
  /\ selLen' = 0
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

\* Content while selection active: peel selLen, append n (host type-over)
ReplaceCommit(n) ==
  /\ selLen > 0
  /\ n \in 1..MaxLen
  /\ LET base == textLen - selLen
     IN /\ base + n <= MaxLen
        /\ textLen' = base + n
        /\ typedToApp' = base + n
        /\ lastTyped' = n
        /\ selLen' = 0

\* Content with selection that is not a valid peel (safety no-op path not modeled;
\* decision layer only peels when hasSuffix — here SelectTrailing always valid)

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ \E s \in 1..MaxLen: SelectTrailing(s)
  \/ ClearSelection
  \/ \E n \in 1..MaxLen: ReplaceCommit(n)

Spec == Init /\ [][Next]_vars

----
TypedMatchesText == typedToApp = textLen

SelInRange == selLen <= textLen

Inv ==
  /\ TypeOK
  /\ TypedMatchesText
  /\ SelInRange

BaitInv == ~TypedMatchesText

StateConstraint == textLen <= MaxLen

====
