---- MODULE ListCounter ----
(*
  Session-scoped numbered list counter for "next number" / "number N".

  Dual of SpokenListITN counter + TextPostProcessor.sessionListCounter.
*)

EXTENDS Integers, TLC

VARIABLES
  n,         \* next list index to emit (always >= 1)
  lastOp     \* "none" | "next" | "set" | "reset"

vars == <<n, lastOp>>

MaxN == 12

TypeOK ==
  /\ n \in 1..MaxN
  /\ lastOp \in {"none", "next", "set", "reset"}

Init ==
  /\ n = 1
  /\ lastOp = "none"

----
\* Emit next number and advance
NextNumber ==
  /\ n < MaxN
  /\ n' = n + 1
  /\ lastOp' = "next"

\* Explicit "number k" sets next to k+1
SetNumber(k) ==
  /\ k \in 1..(MaxN - 1)
  /\ n' = k + 1
  /\ lastOp' = "set"

\* New recording session
Reset ==
  /\ n' = 1
  /\ lastOp' = "reset"

Next ==
  \/ NextNumber
  \/ \E k \in 1..(MaxN - 1): SetNumber(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ n >= 1
  /\ lastOp = "reset" => n = 1

====
