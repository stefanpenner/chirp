---- MODULE InsertStamp ----
(*
  Abstract dual of InsertStamp.formatDate / formatTime.

  Grain: format result length only (not calendar strings).
  Clock is abstract: any Format fires with a positive length
  (injectable nowProvider always yields some instant; output non-empty).

  Inv: after FormatDate or FormatTime, lastLen > 0.
*)

EXTENDS Integers, TLC

VARIABLES
  lastLen,   \* length of last formatted stamp (0 before any format)
  lastOp     \* "none" | "date" | "time"

vars == <<lastLen, lastOp>>

MaxLen == 24

TypeOK ==
  /\ lastLen \in 0..MaxLen
  /\ lastOp \in {"none", "date", "time"}

Init ==
  /\ lastLen = 0
  /\ lastOp = "none"

----
\* formatDate — always non-empty absolute date string
FormatDate(n) ==
  /\ n \in 1..MaxLen
  /\ lastLen' = n
  /\ lastOp' = "date"

\* formatTime — always non-empty local time string
FormatTime(n) ==
  /\ n \in 1..MaxLen
  /\ lastLen' = n
  /\ lastOp' = "time"

Next ==
  \/ \E n \in 1..MaxLen: FormatDate(n)
  \/ \E n \in 1..MaxLen: FormatTime(n)

Spec == Init /\ [][Next]_vars

----
\* Format ops never produce empty output
FormatNonEmpty ==
  lastOp \in {"date", "time"} => lastLen > 0

Inv ==
  /\ TypeOK
  /\ FormatNonEmpty

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~FormatNonEmpty

====
