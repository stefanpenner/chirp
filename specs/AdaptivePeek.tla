---- MODULE AdaptivePeek ----
(*
  Speculative preview cadence: fast while speech yields peeks,
  slower after consecutive idle (no-speech) peeks.

  Dual: DecodePolicy.peekSleepNs + AppState.startPeeking.
*)

EXTENDS Integers, TLC

VARIABLES
  idleMisses,   \* consecutive nil peeks
  interval,     \* "active" | "idle"
  lastHadPeek   \* last peek returned text

vars == <<idleMisses, interval, lastHadPeek>>

Threshold == 2
MaxMiss == 5

TypeOK ==
  /\ idleMisses \in 0..MaxMiss
  /\ interval \in {"active", "idle"}
  /\ lastHadPeek \in BOOLEAN

Init ==
  /\ idleMisses = 0
  /\ interval = "active"
  /\ lastHadPeek = FALSE

----
\* Peek returned text → reset idle, use active interval
PeekHit ==
  /\ idleMisses' = 0
  /\ interval' = "active"
  /\ lastHadPeek' = TRUE

\* Peek returned nil → increment misses; maybe switch to idle interval
PeekMiss ==
  /\ idleMisses < MaxMiss
  /\ idleMisses' = idleMisses + 1
  /\ interval' = IF idleMisses + 1 >= Threshold THEN "idle" ELSE "active"
  /\ lastHadPeek' = FALSE

\* Commit bumps gen — treat as activity (reset)
OnCommit ==
  /\ idleMisses' = 0
  /\ interval' = "active"
  /\ UNCHANGED lastHadPeek

Next ==
  \/ PeekHit
  \/ PeekMiss
  \/ OnCommit

Spec == Init /\ [][Next]_vars

----
\* Idle interval only after enough misses
IdleImpliesMisses ==
  interval = "idle" => idleMisses >= Threshold

\* Active after a hit
HitImpliesActive ==
  lastHadPeek => interval = "active"

Inv ==
  /\ TypeOK
  /\ IdleImpliesMisses

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~IdleImpliesMisses

StateConstraint == idleMisses <= MaxMiss

====
