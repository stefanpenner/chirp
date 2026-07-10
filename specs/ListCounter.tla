---- MODULE ListCounter ----
(*
  Session-scoped numbered list counter for "next number" / "number N".

  Dual of SpokenListITN counter + TextPostProcessor.sessionListCounter.
*)

EXTENDS Integers, TLC

VARIABLES
  n,         \* next list index to emit (always >= 1)
  lastOp     \* "none" | "next" | "set" | "end" | "reset"

vars == <<n, lastOp>>

MaxN == 12

TypeOK ==
  /\ n \in 1..MaxN
  /\ lastOp \in {"none", "next", "set", "end", "reset"}

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

\* Spoken "end list" / "stop numbering" mid-session
EndList ==
  /\ n' = 1
  /\ lastOp' = "end"

\* New recording session
Reset ==
  /\ n' = 1
  /\ lastOp' = "reset"

Next ==
  \/ NextNumber
  \/ \E k \in 1..(MaxN - 1): SetNumber(k)
  \/ EndList
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* end list / reset always leave counter at 1
EndOrResetYieldsOne ==
  lastOp \in {"reset", "end"} => n = 1

Inv ==
  /\ TypeOK
  /\ n >= 1
  /\ EndOrResetYieldsOne

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~EndOrResetYieldsOne

====
