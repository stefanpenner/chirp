---- MODULE ForwardDeleteN ----
(*
  "Forward delete N": press host Forward Delete N times (right-of-caret).

  Keyboard-only — session buffer / edit stack are unchanged.
  Dual of DictationCommand.pressForwardDelete(count) + performPressForwardDelete.

  Model: hostRight = characters under caret to the right (deletable).
  ForwardDeleteN peels min(N, hostRight).
*)

EXTENDS Integers, TLC

CONSTANTS MaxHost, MaxN

VARIABLES
  hostRight,   \* characters under caret to the right
  lastN

vars == <<hostRight, lastN>>

TypeOK ==
  /\ hostRight \in 0..MaxHost
  /\ lastN \in 0..MaxN

Init ==
  /\ hostRight = 0
  /\ lastN = 0

----
\* Characters appear to the right of caret (or caret moves left into text)
Seed(n) ==
  /\ n \in 1..MaxHost
  /\ hostRight + n <= MaxHost
  /\ hostRight' = hostRight + n
  /\ lastN' = 0

\* Forward delete N times (N ≥ 1). No-op peel when host empty.
ForwardDeleteN(k) ==
  /\ k \in 1..MaxN
  /\ LET peeled == IF hostRight < k THEN hostRight ELSE k
     IN /\ hostRight' = hostRight - peeled
        /\ lastN' = peeled

Reset ==
  /\ hostRight' = 0
  /\ lastN' = 0

Next ==
  \/ \E n \in 1..MaxHost: Seed(n)
  \/ \E k \in 1..MaxN: ForwardDeleteN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
ForwardSafe ==
  /\ hostRight >= 0
  /\ lastN <= MaxN
  /\ lastN <= MaxHost

Inv ==
  /\ TypeOK
  /\ ForwardSafe

BaitInv == ~ForwardSafe

StateConstraint == hostRight <= MaxHost

====
