---- MODULE FuzzyCommand ----
(*
  Full-utterance fuzzy command match: unique nearest surface within MaxDist.

  Dual of CommandNearMiss.fuzzyMatch (after exact map + glue expand):
    - starter gate (abstract: starterOK)
    - short utterance gate (abstract: shortOK)
    - multi-word only (words >= 2)
    - unique min distance in 1..MaxDist → Match
    - ties at min → Ambiguous → None
    - min > MaxDist or no candidates → None
    - min = 0 (exact surface) → Exact (parse handles; no rewrite required)

  Grain: abstract distances only (no string model).
*)

EXTENDS Integers, TLC

CONSTANTS
  MaxSurfaces,  \* 1..MaxSurfaces surfaces considered
  MaxDist       \* max allowed edit distance (product: 1)

VARIABLES
  starterOK,    \* first token is a command starter
  shortOK,      \* word/char bounds pass
  multiWord,    \* words >= 2
  nInRange,     \* surfaces with dist <= MaxDist
  minDist,      \* min dist among in-range (0..MaxDist) or -1 if none
  ties,         \* count at minDist among in-range
  decision      \* "none" | "exact" | "match" | "ambiguous"

vars == <<starterOK, shortOK, multiWord, nInRange, minDist, ties, decision>>

TypeOK ==
  /\ starterOK \in BOOLEAN
  /\ shortOK \in BOOLEAN
  /\ multiWord \in BOOLEAN
  /\ nInRange \in 0..MaxSurfaces
  /\ minDist \in -1..MaxDist
  /\ ties \in 0..MaxSurfaces
  /\ decision \in {"none", "exact", "match", "ambiguous"}
  /\ (nInRange = 0 => minDist = -1 /\ ties = 0)
  /\ (nInRange > 0 => minDist >= 0 /\ ties >= 1 /\ ties <= nInRange)

Init ==
  /\ starterOK = FALSE
  /\ shortOK = FALSE
  /\ multiWord = FALSE
  /\ nInRange = 0
  /\ minDist = -1
  /\ ties = 0
  /\ decision = "none"

----
\* Pure decision dual of fuzzyMatch (inlined — no higher-order call in action).
DecisionOf(sOK, shOK, multi, n, md, t) ==
  CASE (~sOK) \/ (~shOK) \/ (~multi) \/ (n = 0) \/ (md = -1) -> "none"
    [] (md = 0) /\ (t = 1) -> "exact"
    [] (md = 0) /\ (t # 1) -> "ambiguous"
    [] (md >= 1) /\ (md <= MaxDist) /\ (t = 1) -> "match"
    [] (md >= 1) /\ (md <= MaxDist) /\ (t # 1) -> "ambiguous"
    [] OTHER -> "none"

\* Observe a hyp: gates + distance summary (nondeterministic abstract input)
Observe(sOK, shOK, multi, n, md, t) ==
  /\ sOK \in BOOLEAN
  /\ shOK \in BOOLEAN
  /\ multi \in BOOLEAN
  /\ n \in 0..MaxSurfaces
  /\ md \in -1..MaxDist
  /\ t \in 0..MaxSurfaces
  /\ (n = 0 => md = -1 /\ t = 0)
  /\ (n > 0 => md >= 0 /\ t >= 1 /\ t <= n)
  /\ starterOK' = sOK
  /\ shortOK' = shOK
  /\ multiWord' = multi
  /\ nInRange' = n
  /\ minDist' = md
  /\ ties' = t
  /\ decision' = DecisionOf(sOK, shOK, multi, n, md, t)

Next ==
  \E sOK \in BOOLEAN:
    \E shOK \in BOOLEAN:
      \E multi \in BOOLEAN:
        \E n \in 0..MaxSurfaces:
          \E md \in -1..MaxDist:
            \E t \in 0..MaxSurfaces:
              Observe(sOK, shOK, multi, n, md, t)

Spec == Init /\ [][Next]_vars

----
\* Safety: match only when unique positive distance and gates pass
MatchImpliesUnique ==
  decision = "match" =>
    /\ starterOK
    /\ shortOK
    /\ multiWord
    /\ nInRange >= 1
    /\ minDist \in 1..MaxDist
    /\ ties = 1

\* Ambiguous never yields match
AmbiguousIsSafe ==
  decision = "ambiguous" => ties > 1

\* No gates → never match
GatesRequired ==
  (~starterOK \/ ~shortOK \/ ~multiWord) => decision # "match"

\* Exact is only dist 0 unique
ExactImpliesDist0 ==
  decision = "exact" => (minDist = 0 /\ ties = 1)

Inv ==
  /\ TypeOK
  /\ MatchImpliesUnique
  /\ AmbiguousIsSafe
  /\ GatesRequired
  /\ ExactImpliesDist0

BaitInv == ~MatchImpliesUnique

StateConstraint == nInRange <= MaxSurfaces

====
