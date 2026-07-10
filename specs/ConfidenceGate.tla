---- MODULE ConfidenceGate ----
(*
  Accept/reject ASR hypotheses from optional token confidence.

  hasScores = FALSE → always accept (model gave no log-probs)
  hasScores = TRUE  → accept iff meanLogProb >= length-aware threshold

  tokenCount abstract: 1 = short, 2 = medium, 3 = long
  Short is stricter: a mean that medium accepts may reject on short.

  Dual: ConfidenceGate.swift
*)

EXTENDS Integers, Reals, TLC

VARIABLES
  hasScores,
  tokenCount,    \* abstract length band: 1 short, 2 medium, 3 long
  meanLogProb,   \* abstract: -100..0 when hasScores (×10 scale)
  accepted

vars == <<hasScores, tokenCount, meanLogProb, accepted>>

\* Thresholds × 10 for integer TLC
\* short -3.0, medium -4.0, long -5.0 (base minMeanLogProb)
ThresholdX10(n) ==
  CASE n = 1 -> -30
    [] n = 2 -> -40
    [] OTHER -> -50

TypeOK ==
  /\ hasScores \in BOOLEAN
  /\ tokenCount \in 1..3
  /\ meanLogProb \in -100..0
  /\ accepted \in BOOLEAN

Init ==
  /\ hasScores = FALSE
  /\ tokenCount = 3
  /\ meanLogProb = 0
  /\ accepted = TRUE

----
ObserveNoScores ==
  /\ hasScores' = FALSE
  /\ tokenCount' = tokenCount
  /\ meanLogProb' = 0
  /\ accepted' = TRUE

ObserveScores(n, m) ==
  /\ n \in 1..3
  /\ m \in -100..0
  /\ hasScores' = TRUE
  /\ tokenCount' = n
  /\ meanLogProb' = m
  /\ accepted' = (m >= ThresholdX10(n))

Next ==
  \/ ObserveNoScores
  \/ \E n \in 1..3, m \in -100..0: ObserveScores(n, m)

Spec == Init /\ [][Next]_vars

----
\* No scores ⇒ always accepted
NoScoresAccept ==
  ~hasScores => accepted

\* With scores: accepted iff mean >= length-aware threshold
ScoresPolicy ==
  hasScores => (accepted <=> meanLogProb >= ThresholdX10(tokenCount))

\* Short is stricter than long: mean in (-50,-30) rejects short, accepts long
\* Abstract: m = -40 → short (n=1) rejects, long (n=3) accepts
ShortStricterThanLong ==
  hasScores => (
    (tokenCount = 1 /\ meanLogProb = -40) => ~accepted
  )

Inv ==
  /\ TypeOK
  /\ NoScoresAccept
  /\ ScoresPolicy
  /\ ShortStricterThanLong

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~NoScoresAccept

====
