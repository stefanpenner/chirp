---- MODULE BackspaceN ----
(*
  Dragon "Backspace <n>": press host Backspace N times.

  Keyboard-only — session buffer / edit stack are unchanged.
  Dual of DictationCommand.pressBackspace(count) + performPressBackspace.

  Model: hostChars = characters still present in the focused app
  (not Chirp session buffer). BackspaceN peels min(N, hostChars).
*)

EXTENDS Integers, TLC

CONSTANTS MaxHost, MaxN

VARIABLES
  hostChars,   \* characters under caret to the left (deletable)
  lastN        \* last backspace count applied (0 if none / empty)

vars == <<hostChars, lastN>>

TypeOK ==
  /\ hostChars \in 0..MaxHost
  /\ lastN \in 0..MaxN

Init ==
  /\ hostChars = 0
  /\ lastN = 0

----
\* App gains characters (dictation / type)
Type(n) ==
  /\ n \in 1..MaxHost
  /\ hostChars + n <= MaxHost
  /\ hostChars' = hostChars + n
  /\ lastN' = 0

\* Backspace N times (N ≥ 1). No-op peel when host empty.
BackspaceN(k) ==
  /\ k \in 1..MaxN
  /\ LET peeled == IF hostChars < k THEN hostChars ELSE k
     IN /\ hostChars' = hostChars - peeled
        /\ lastN' = peeled

Reset ==
  /\ hostChars' = 0
  /\ lastN' = 0

Next ==
  \/ \E n \in 1..MaxHost: Type(n)
  \/ \E k \in 1..MaxN: BackspaceN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* Never go negative; lastN never exceeds MaxN or previous host
BackspaceSafe ==
  /\ hostChars >= 0
  /\ lastN <= MaxN
  /\ lastN <= MaxHost

Inv ==
  /\ TypeOK
  /\ BackspaceSafe

BaitInv == ~BackspaceSafe

StateConstraint == hostChars <= MaxHost

====
