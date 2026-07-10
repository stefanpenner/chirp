---- MODULE ConfidenceGate ----
(*
  Accept/reject ASR hypotheses from optional token confidence.

  hasScores = FALSE → always accept (model gave no log-probs)
  hasScores = TRUE  → accept iff meanLogProb >= threshold

  Dual: ConfidenceGate.swift
*)

EXTENDS Integers, Reals, TLC

VARIABLES
  hasScores,
  meanLogProb,   \* abstract: -10..0 when hasScores
  accepted

vars == <<hasScores, meanLogProb, accepted>>

\* Threshold × 10 for integer TLC (threshold = -5.0)
ThresholdX10 == -50

TypeOK ==
  /\ hasScores \in BOOLEAN
  /\ meanLogProb \in -100..0
  /\ accepted \in BOOLEAN

Init ==
  /\ hasScores = FALSE
  /\ meanLogProb = 0
  /\ accepted = TRUE

----
ObserveNoScores ==
  /\ hasScores' = FALSE
  /\ meanLogProb' = 0
  /\ accepted' = TRUE

ObserveScores(m) ==
  /\ m \in -100..0
  /\ hasScores' = TRUE
  /\ meanLogProb' = m
  /\ accepted' = (m >= ThresholdX10)

Next ==
  \/ ObserveNoScores
  \/ \E m \in -100..0: ObserveScores(m)

Spec == Init /\ [][Next]_vars

----
\* No scores ⇒ always accepted
NoScoresAccept ==
  ~hasScores => accepted

\* With scores: accepted iff mean >= threshold
ScoresPolicy ==
  hasScores => (accepted <=> meanLogProb >= ThresholdX10)

Inv ==
  /\ TypeOK
  /\ NoScoresAccept
  /\ ScoresPolicy

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~NoScoresAccept

====
