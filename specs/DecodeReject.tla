---- MODULE DecodeReject ----
(*
  Energy/silence composite reject gate for ASR hypotheses.

  hasScores /\ lowMean     → reject (same as ConfidenceGate)
  speechFrames = 0 /\ ~hypEmpty → reject (garbage on pure silence)
  speechFrames = 0 /\ hypEmpty  → accept (nothing to type)
  speechFrames ≤ 1 /\ hypFiller /\ ~hypEmpty → reject (common silence fillers)
  speechFrames > 0 real short words → may accept

  Dual: DecodeReject.swift
*)

EXTENDS Integers, TLC

VARIABLES
  hasScores,
  lowMean,        \* meanLogProb < threshold when hasScores
  speechFrames,   \* 0..2 abstract energy-speech frame count
  hypEmpty,
  hypFiller,      \* whole hyp is a known filler word
  reject

vars == <<hasScores, lowMean, speechFrames, hypEmpty, hypFiller, reject>>

TypeOK ==
  /\ hasScores \in BOOLEAN
  /\ lowMean \in BOOLEAN
  /\ speechFrames \in 0..2
  /\ hypEmpty \in BOOLEAN
  /\ hypFiller \in BOOLEAN
  /\ reject \in BOOLEAN

\* Pure decision matching DecodeReject.shouldReject
ShouldReject(hasSc, lowM, frames, empty, filler) ==
  \/ (hasSc /\ lowM)
  \/ (frames = 0 /\ ~empty)
  \/ (frames <= 1 /\ filler /\ ~empty)

Init ==
  /\ hasScores = FALSE
  /\ lowMean = FALSE
  /\ speechFrames = 0
  /\ hypEmpty = TRUE
  /\ hypFiller = FALSE
  /\ reject = FALSE

Observe(hasSc, lowM, frames, empty, filler) ==
  /\ hasScores' = hasSc
  /\ lowMean' = lowM
  /\ speechFrames' = frames
  /\ hypEmpty' = empty
  /\ hypFiller' = filler
  /\ reject' = ShouldReject(hasSc, lowM, frames, empty, filler)

Next ==
  \E hasSc, lowM, empty, filler \in BOOLEAN, frames \in 0..2:
    Observe(hasSc, lowM, frames, empty, filler)

Spec == Init /\ [][Next]_vars

----
\* Pure silence with non-empty hyp must reject
SilenceNonEmptyRejects ==
  (speechFrames = 0 /\ ~hypEmpty) => reject

\* Low mean when scores exist must reject
LowMeanRejects ==
  (hasScores /\ lowMean) => reject

\* Known filler on zero/one speech frame must reject
FillerLowFramesRejects ==
  (speechFrames <= 1 /\ hypFiller /\ ~hypEmpty) => reject

\* Empty hyp on silence is fine (accept) unless low-mean scores reject
SilenceEmptyAccepts ==
  (speechFrames = 0 /\ hypEmpty /\ ~(hasScores /\ lowMean)) => ~reject

Inv ==
  /\ TypeOK
  /\ SilenceNonEmptyRejects
  /\ LowMeanRejects
  /\ FillerLowFramesRejects
  /\ SilenceEmptyAccepts

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~SilenceNonEmptyRejects

====
