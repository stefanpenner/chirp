---- MODULE TranscriberBuffer ----
(*
  Dual-buffer commit policy for Transcriber (docs/audio-pipeline.md).

  Purpose: pendingAudio is the source of truth for peek, mid-recording
  commit (feedAudio), and flush. VAD only signals *when* to commit —
  not *what* audio to decode. This prevents onset-lag clipping.

  Empty ASR on a VAD endpoint must NOT clear pending (false endpoint).
  Only a non-empty decode clears the buffer.

  Grain: abstract sample counts (units), not real PCM.
*)

EXTENDS Integers, TLC

VARIABLES
  pending,       \* samples since last successful commit
  vadActive,     \* VAD currently in speech
  lastCommitSrc, \* "none" | "pending" — what we last decoded from
  lastCommitOk   \* whether last commit attempt produced text

vars == <<pending, vadActive, lastCommitSrc, lastCommitOk>>

MaxPending == 20  \* model-check bound

TypeOK ==
  /\ pending \in 0..MaxPending
  /\ vadActive \in BOOLEAN
  /\ lastCommitSrc \in {"none", "pending"}
  /\ lastCommitOk \in BOOLEAN

Init ==
  /\ pending = 0
  /\ vadActive = FALSE
  /\ lastCommitSrc = "none"
  /\ lastCommitOk = FALSE

----
\* Ingest a chunk of audio (always appends to pending)
Ingest ==
  /\ pending < MaxPending
  /\ pending' = pending + 1
  /\ lastCommitOk' = FALSE  \* buffer no longer post-success empty
  /\ UNCHANGED <<vadActive, lastCommitSrc>>

\* VAD marks speech start
SpeechStart ==
  /\ ~vadActive
  /\ pending > 0
  /\ vadActive' = TRUE
  /\ UNCHANGED <<pending, lastCommitSrc, lastCommitOk>>

\* Successful commit: non-empty ASR from pending → clear buffer
CommitOk ==
  /\ vadActive
  /\ pending >= 1
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"
  /\ lastCommitOk' = TRUE

\* Empty ASR on VAD endpoint: keep pending (false endpoint)
CommitEmpty ==
  /\ vadActive
  /\ pending >= 1
  /\ pending' = pending
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"
  /\ lastCommitOk' = FALSE

\* End of recording flush with text: clear pending
FlushOk ==
  /\ pending >= 1
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"
  /\ lastCommitOk' = TRUE

\* Flush with nothing useful: still clears (end of session)
FlushEmpty ==
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "pending"
  /\ lastCommitOk' = FALSE

\* Cancel / reset
Reset ==
  /\ pending' = 0
  /\ vadActive' = FALSE
  /\ lastCommitSrc' = "none"
  /\ lastCommitOk' = FALSE

Next ==
  \/ Ingest
  \/ SpeechStart
  \/ CommitOk
  \/ CommitEmpty
  \/ FlushOk
  \/ FlushEmpty
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* Safety: decode source is always pending (never a VAD-trimmed segment model)
CommitUsesPending ==
  lastCommitSrc \in {"none", "pending"}

\* After a successful commit/flush, buffer is empty
SuccessImpliesEmpty ==
  lastCommitOk => pending = 0

Inv ==
  /\ TypeOK
  /\ CommitUsesPending
  /\ SuccessImpliesEmpty

StateConstraint == pending <= MaxPending

====
