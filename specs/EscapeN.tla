---- MODULE EscapeN ----
(*
  Dragon "press escape N times" / "escape key 3 times".

  Keyboard-only — session buffer / edit stack are unchanged.
  Does not cancel the Chirp recording session (physical ESC hotkey still does).

  Dual of:
    DictationCommand.pressEscape(count)
    AppState.performPressEscape
    TextInserter.pressEscape × N

  Model: total host Escape key posts. EscapeN adds k posts (k ≥ 1).
*)

EXTENDS Integers, TLC

CONSTANTS MaxPresses, MaxN

VARIABLES
  presses,  \* cumulative Escape key posts on host
  lastN     \* last count applied (0 if none)

vars == <<presses, lastN>>

TypeOK ==
  /\ presses \in 0..MaxPresses
  /\ lastN \in 0..MaxN

Init ==
  /\ presses = 0
  /\ lastN = 0

----
\* Escape N times (N ≥ 1). Caps at MaxPresses for model finiteness.
EscapeN(k) ==
  /\ k \in 1..MaxN
  /\ presses + k <= MaxPresses
  /\ presses' = presses + k
  /\ lastN' = k

Reset ==
  /\ presses' = 0
  /\ lastN' = 0

Next ==
  \/ \E k \in 1..MaxN: EscapeN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* Never exceed bounds; lastN is a real press count when set
EscapeSafe ==
  /\ presses >= 0
  /\ presses <= MaxPresses
  /\ lastN <= MaxN
  /\ lastN >= 0

\* lastN is either 0 (idle/reset) or in 1..MaxN after EscapeN
LastNSane ==
  lastN = 0 \/ lastN \in 1..MaxN

Inv ==
  /\ TypeOK
  /\ EscapeSafe
  /\ LastNSane

BaitInv == ~EscapeSafe

StateConstraint == presses <= MaxPresses

====
