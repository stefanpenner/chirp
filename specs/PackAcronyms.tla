---- MODULE PackAcronyms ----
(*
  Safer auto-pack of spoken single-letter runs into acronyms.

  Abstract:
    runLen \in 0..5  — length of a single-letter run
    isAllowlistPair  — true for common 2-letter pairs (id/ui/ok/…)
    packs            — whether the run is joined uppercase

  Packs when:
    runLen >= 3  OR  (runLen = 2 /\ isAllowlistPair)

  Does not pack:
    runLen < 2  OR  (runLen = 2 /\ ~isAllowlistPair)

  Dual of SpellTransform.packAcronyms / shouldPackAcronym (SpellMode.swift).
*)

EXTENDS Integers, TLC

VARIABLES
  runLen,            \* 0..5 abstract single-letter run length
  isAllowlistPair,   \* true for id/ui/ok/… allowlisted pairs
  packs              \* whether the run is packed to an uppercase acronym

vars == <<runLen, isAllowlistPair, packs>>

TypeOK ==
  /\ runLen \in 0..5
  /\ isAllowlistPair \in BOOLEAN
  /\ packs \in BOOLEAN

\* Pure decision matching SpellTransform.shouldPackAcronym
ShouldPack(len, allow) ==
  \/ len >= 3
  \/ (len = 2 /\ allow)

Init ==
  /\ runLen = 0
  /\ isAllowlistPair = FALSE
  /\ packs = FALSE

ObserveRun(len, allow) ==
  /\ runLen' = len
  /\ isAllowlistPair' = allow
  /\ packs' = ShouldPack(len, allow)

Next ==
  \E len \in 0..5, allow \in BOOLEAN:
    ObserveRun(len, allow)

Spec == Init /\ [][Next]_vars

----
\* packs is exactly the safer packing rule
PacksIffRule ==
  packs <=> (runLen >= 3 \/ (runLen = 2 /\ isAllowlistPair))

\* Long runs always pack (API, URL, …)
LongRunsPack ==
  runLen >= 3 => packs

\* Unlisted pairs stay split (a b, x y)
UnlistedPairsStay ==
  (runLen = 2 /\ ~isAllowlistPair) => ~packs

\* Single letters / empty never pack
ShortNeverPacks ==
  runLen < 2 => ~packs

Inv ==
  /\ TypeOK
  /\ PacksIffRule
  /\ LongRunsPack
  /\ UnlistedPairsStay
  /\ ShortNeverPacks

\* Bait: negation of the core packing equivalence (must FAIL under TLC)
BaitInv == ~PacksIffRule

====
