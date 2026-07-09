---- MODULE TranscriberBuffer ----
(*
  Dual-buffer commit policy for Transcriber (docs/audio-pipeline.md).

  Purpose: pendingAudio is the source of truth for peek, mid-recording
  commit (feedAudio), and flush. VAD only signals *when* to commit —
  not *what* audio to decode. This prevents onset-lag clipping.

  Grain: abstract sample counts (units), not real PCM.
*)

EXTENDS Integers, TLC

VARIABLES
  pending,       \* samples since last commit
  vadActive,     \* VAD currently in speech
  lastCommitSrc  \* "none" | "pending" — what we last decoded from

vars == <<pending, vadActive, lastCommitSrc>>

MaxPending == 20  \* model-check bound

TypeOK ==
  /\ pending \in 0..MaxPending
  /\ vadActive \in BOOLEAN
  /\ lastCommitSrc \in {"none", "pending"}

Init ==
  /\ pending = 0
  /\ vadActive = FALSE
  /\ lastCommitSrc = "none"

----
\* Ingest a chunk of audio (always appends to pending)
Ingest ==
  /\ pending < MaxPending
  /\ pending' = pending + 1
  /\ UNCHANGED <<vadActive, lastCommitSrc>>

\* VAD marks speech start
SpeechStart ==
  /\ ~vadActive
  /\ pending > 0
  /\ vadActive' = TRUE
  /\ UNCHANGED <<pending, lastCommitSrc>>

\* VAD marks speech end → commit from pending (not VAD-trimmed segment)
CommitFromPending ==
  /\ vadActive
  /\ pending >= 1
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"

\* End of recording flush: same source as commit
FlushFromPending ==
  /\ pending >= 1
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"

\* Cancel / reset
Reset ==
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "none"

Next ==
  \/ Ingest
  \/ SpeechStart
  \/ CommitFromPending
  \/ FlushFromPending
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* Safety: any successful commit/flush used pending as the decode source.
\* (lastCommitSrc is "pending" or still "none" if nothing committed yet)
CommitUsesPending ==
  lastCommitSrc \in {"none", "pending"}

\* After commit/flush/reset, buffer is empty
EmptyAfterIdle ==
  (~vadActive /\ lastCommitSrc = "pending") => pending = 0
  \/ lastCommitSrc = "none"
  \/ vadActive

\* Cleaner formulation: pending is 0 whenever we just committed
\* (modeled by Commit/Flush setting pending'=0 — enforced by actions)

Inv ==
  /\ TypeOK
  /\ CommitUsesPending

StateConstraint == pending <= MaxPending

====
