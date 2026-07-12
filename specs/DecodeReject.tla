---- MODULE DecodeReject ----
(*
  Energy/silence composite reject gate for ASR hypotheses.

  hasScores /\ lowMean     → reject (same as ConfidenceGate)
  speechFrames = 0 /\ ~hypEmpty → reject (garbage on pure silence)
  speechFrames = 0 /\ hypEmpty  → accept (nothing to type)
  speechFrames ≤ 1 /\ hypFiller /\ ~hypEmpty → reject (common silence fillers)
  multiWord /\ ~hasScores /\ frames ≤ 2 /\ ~hypEmpty → reject
    (Parakeet nil log-probs + multi-token near-silence dumps)
  speechFrames > 0 real short words → may accept

  Dual: DecodeReject.swift
*)

EXTENDS Integers, TLC

VARIABLES
  hasScores,
  lowMean,        \* meanLogProb < threshold when hasScores
  speechFrames,   \* 0..8 abstract energy-speech frame count
  hypEmpty,
  hypFiller,      \* whole hyp is a known filler word
  multiWord,      \* ≥2 whitespace tokens
  reject

vars == <<hasScores, lowMean, speechFrames, hypEmpty, hypFiller, multiWord, reject>>

TypeOK ==
  /\ hasScores \in BOOLEAN
  /\ lowMean \in BOOLEAN
  /\ speechFrames \in 0..8
  /\ hypEmpty \in BOOLEAN
  /\ hypFiller \in BOOLEAN
  /\ multiWord \in BOOLEAN
  /\ reject \in BOOLEAN
  /\ (hypEmpty => ~multiWord)  \* empty has no tokens
  /\ (hypEmpty => ~hypFiller)

\* Pure decision matching DecodeReject.shouldReject
ShouldReject(hasSc, lowM, frames, empty, filler, multi) ==
  \/ (hasSc /\ lowM)
  \/ (frames = 0 /\ ~empty)
  \/ (frames <= 1 /\ filler /\ ~empty)
  \/ (multi /\ ~hasSc /\ frames <= 2 /\ ~empty)

Init ==
  /\ hasScores = FALSE
  /\ lowMean = FALSE
  /\ speechFrames = 0
  /\ hypEmpty = TRUE
  /\ hypFiller = FALSE
  /\ multiWord = FALSE
  /\ reject = FALSE

Observe(hasSc, lowM, frames, empty, filler, multi) ==
  /\ hasScores' = hasSc
  /\ lowMean' = lowM
  /\ speechFrames' = frames
  /\ hypEmpty' = empty
  /\ hypFiller' = filler
  /\ multiWord' = multi
  /\ reject' = ShouldReject(hasSc, lowM, frames, empty, filler, multi)

Next ==
  \E hasSc, lowM, empty, filler, multi \in BOOLEAN, frames \in 0..8:
    /\ (empty => ~multi)
    /\ (empty => ~filler)
    /\ Observe(hasSc, lowM, frames, empty, filler, multi)

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

\* Multi-word near-silence without scores must reject
MultiWordLowEnergyNilScoresRejects ==
  (multiWord /\ ~hasScores /\ speechFrames <= 2 /\ ~hypEmpty) => reject

\* Empty hyp on silence is fine (accept) unless low-mean scores reject
SilenceEmptyAccepts ==
  (speechFrames = 0 /\ hypEmpty /\ ~(hasScores /\ lowMean)) => ~reject

\* Single-token short speech with frames and no low-mean scores accepts
ShortSpeechMayAccept ==
  (~multiWord /\ ~hypEmpty /\ ~hypFiller /\ speechFrames >= 2
    /\ ~(hasScores /\ lowMean)) => ~reject

Inv ==
  /\ TypeOK
  /\ SilenceNonEmptyRejects
  /\ LowMeanRejects
  /\ FillerLowFramesRejects
  /\ MultiWordLowEnergyNilScoresRejects
  /\ SilenceEmptyAccepts
  /\ ShortSpeechMayAccept

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~SilenceNonEmptyRejects

====
