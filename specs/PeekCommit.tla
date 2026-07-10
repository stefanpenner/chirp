---- MODULE PeekCommit ----
(*
  Speculative preview vs committed-segment generation counter.

  Purpose: prove stale peeks never overwrite UI after a newer commit.
  Mirrors commitGen / peek flow in ChirpApp.startPeeking + consumer.

  NOT modeled: real ASR text, timing, MainActor scheduling details.
*)

EXTENDS Integers, TLC

VARIABLES
  status,       \* "recording" | "idle"
  commitGen,    \* increments on each committed segment
  peekGen,      \* gen captured when a peek started (or -1 if none in flight)
  speculative,  \* whether speculative text is non-empty
  session       \* session id

vars == <<status, commitGen, peekGen, speculative, session>>

MaxGen == 5
MaxSession == 3

TypeOK ==
  /\ status \in {"recording", "idle"}
  /\ commitGen \in 0..MaxGen
  /\ peekGen \in -1..MaxGen
  /\ speculative \in BOOLEAN
  /\ session \in 0..MaxSession

Init ==
  /\ status = "idle"
  /\ commitGen = 0
  /\ peekGen = -1
  /\ speculative = FALSE
  /\ session = 0

----
StartRecording ==
  /\ status = "idle"
  /\ session < MaxSession
  /\ status' = "recording"
  /\ session' = session + 1
  /\ commitGen' = 0
  /\ peekGen' = -1
  /\ speculative' = FALSE

\* Peek starts: capture current commit gen
StartPeek ==
  /\ status = "recording"
  /\ peekGen = -1
  /\ peekGen' = commitGen
  /\ UNCHANGED <<status, commitGen, speculative, session>>

\* Peek completes successfully only if gen still matches
PeekApply ==
  /\ status = "recording"
  /\ peekGen >= 0
  /\ peekGen = commitGen
  /\ speculative' = TRUE
  /\ peekGen' = -1
  /\ UNCHANGED <<status, commitGen, session>>

\* Peek discarded because a commit landed mid-inference
PeekStale ==
  /\ status = "recording"
  /\ peekGen >= 0
  /\ peekGen # commitGen
  /\ peekGen' = -1
  /\ UNCHANGED <<status, commitGen, speculative, session>>

\* VAD commit: bump gen and clear speculative
Commit ==
  /\ status = "recording"
  /\ commitGen < MaxGen
  /\ commitGen' = commitGen + 1
  /\ speculative' = FALSE
  /\ UNCHANGED <<status, peekGen, session>>

StopToIdle ==
  /\ status = "recording"
  /\ status' = "idle"
  /\ peekGen' = -1
  /\ speculative' = FALSE
  /\ UNCHANGED <<commitGen, session>>

Cancel ==
  /\ status = "recording"
  /\ session < MaxSession
  /\ status' = "idle"
  /\ session' = session + 1
  /\ commitGen' = 0
  /\ peekGen' = -1
  /\ speculative' = FALSE

Next ==
  \/ StartRecording
  \/ StartPeek
  \/ PeekApply
  \/ PeekStale
  \/ Commit
  \/ StopToIdle
  \/ Cancel

Spec == Init /\ [][Next]_vars

----
\* Stale peeks never apply: PeekApply requires peekGen = commitGen
\* Speculative text only while recording
SpecOnlyWhileRecording ==
  speculative => status = "recording"

\* In-flight peek gen is never ahead of commit gen
PeekGenBounded ==
  peekGen <= commitGen

Inv ==
  /\ TypeOK
  /\ SpecOnlyWhileRecording
  /\ PeekGenBounded

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~SpecOnlyWhileRecording

StateConstraint ==
  /\ commitGen <= MaxGen
  /\ session <= MaxSession

====
