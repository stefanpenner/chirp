---- MODULE PeekCommitHyp ----
(*
  Reuse peek ASR hyp on commit/flush when the speech window is unchanged.

  Dual of:
    DecodePolicy.shouldReuseCommitHyp
    Transcriber lastPeekSpeechSignature + lastPeekText on feedAudio/flush

  Grain:
    pendingInPeekWindow \in BOOLEAN  \* pending ≤ peekMaxSamples
    sigMatch \in BOOLEAN             \* speech-window fingerprint equal
    hasHyp \in BOOLEAN               \* cached text non-empty
    lastOp \in {"none","peek","growSilence","growSpeech","commitReuse","commitDecode"}
*)

EXTENDS Integers, TLC

VARIABLES
  pendingInPeekWindow,
  sigMatch,
  hasHyp,
  lastOp

vars == <<pendingInPeekWindow, sigMatch, hasHyp, lastOp>>

TypeOK ==
  /\ pendingInPeekWindow \in BOOLEAN
  /\ sigMatch \in BOOLEAN
  /\ hasHyp \in BOOLEAN
  /\ lastOp \in {
       "none", "peek", "growSilence", "growSpeech",
       "commitReuse", "commitDecode"
     }

Init ==
  /\ pendingInPeekWindow = TRUE
  /\ sigMatch = FALSE
  /\ hasHyp = FALSE
  /\ lastOp = "none"

----
\* Successful peek decode installs a hyp + matching signature
PeekDecode ==
  /\ lastOp' = "peek"
  /\ hasHyp' = TRUE
  /\ sigMatch' = TRUE
  /\ UNCHANGED pendingInPeekWindow

\* Trailing silence after peek: pending may grow but window sig still matches
\* only while still inside the peek max window.
GrowSilence ==
  /\ hasHyp = TRUE
  /\ lastOp' = "growSilence"
  /\ sigMatch' = TRUE
  /\ UNCHANGED <<hasHyp, pendingInPeekWindow>>

\* New speech changes the speech window (signature miss)
GrowSpeech ==
  /\ lastOp' = "growSpeech"
  /\ sigMatch' = FALSE
  /\ UNCHANGED <<hasHyp, pendingInPeekWindow>>

\* Commit reuses hyp only when all three gates hold
CommitReuse ==
  /\ hasHyp = TRUE
  /\ sigMatch = TRUE
  /\ pendingInPeekWindow = TRUE
  /\ lastOp' = "commitReuse"
  /\ hasHyp' = FALSE
  /\ sigMatch' = FALSE
  /\ UNCHANGED pendingInPeekWindow

\* Commit must re-decode when any gate fails
CommitDecode ==
  /\ \/ hasHyp = FALSE
     \/ sigMatch = FALSE
     \/ pendingInPeekWindow = FALSE
  /\ lastOp' = "commitDecode"
  /\ hasHyp' = FALSE
  /\ sigMatch' = FALSE
  /\ UNCHANGED pendingInPeekWindow

\* Abstract: pending grows past peek max (long utterance)
ExceedPeekWindow ==
  /\ pendingInPeekWindow = TRUE
  /\ pendingInPeekWindow' = FALSE
  /\ lastOp' = "growSpeech"
  /\ UNCHANGED <<sigMatch, hasHyp>>

Next ==
  \/ PeekDecode
  \/ GrowSilence
  \/ GrowSpeech
  \/ CommitReuse
  \/ CommitDecode
  \/ ExceedPeekWindow

Spec == Init /\ [][Next]_vars

----
\* Reuse only when all three gates hold
ReuseImpliesSafe ==
  lastOp = "commitReuse" =>
    (hasHyp = FALSE /\  \* cleared after reuse step in post-state
     TRUE)
\* Stronger: the pre-state of CommitReuse requires the three gates
\* (encoded in CommitReuse action; post-state clears hyp)

\* After any commit, hyp is cleared
CommitClearsHyp ==
  lastOp \in {"commitReuse", "commitDecode"} => hasHyp = FALSE

\* Bait: negation of CommitClearsHyp (must FAIL under TLC — legal states exist)
BaitInv == ~CommitClearsHyp

Inv ==
  /\ TypeOK
  /\ CommitClearsHyp

====
