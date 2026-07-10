---- MODULE CapNext ----
(*
  One-shot "cap next": arm capitalization of the next content commit,
  then clear the arm after that commit.

  Dual of AppState.capitalizeNextWord + shapeContent / DictationCommand.capNext.
*)

EXTENDS Integers, TLC

VARIABLES
  armed,      \* TRUE after "cap next", cleared on next content Commit
  commits,    \* number of content commits this session
  lastOp      \* "none" | "arm" | "commit" | "commitArmed" | "reset"

vars == <<armed, commits, lastOp>>

TypeOK ==
  /\ armed \in BOOLEAN
  /\ commits \in 0..8
  /\ lastOp \in {"none", "arm", "commit", "commitArmed", "reset"}

Init ==
  /\ armed = FALSE
  /\ commits = 0
  /\ lastOp = "none"

----
\* Spoken "cap next" / "capitalize next" arms the one-shot flag
ArmCapNext ==
  /\ armed' = TRUE
  /\ lastOp' = "arm"
  /\ UNCHANGED commits

\* Content commit while not armed — normal
Commit ==
  /\ ~armed
  /\ commits < 8
  /\ commits' = commits + 1
  /\ lastOp' = "commit"
  /\ UNCHANGED armed

\* Content commit while armed — capitalize first word (modeled as commit) and clear arm
CommitArmed ==
  /\ armed
  /\ commits < 8
  /\ commits' = commits + 1
  /\ armed' = FALSE
  /\ lastOp' = "commitArmed"

\* New hold-to-talk session or cancel
Reset ==
  /\ armed' = FALSE
  /\ commits' = 0
  /\ lastOp' = "reset"

Next ==
  \/ ArmCapNext
  \/ Commit
  \/ CommitArmed
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* After a commit-while-armed, flag is cleared
CommitArmedClears == lastOp = "commitArmed" => ~armed

\* After reset, never armed
ResetClears == lastOp = "reset" => ~armed

\* Arm sets the flag (enforced by ArmCapNext)
ArmSetsFlag == lastOp = "arm" => armed

Inv ==
  /\ TypeOK
  /\ CommitArmedClears
  /\ ResetClears
  /\ ArmSetsFlag

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~CommitArmedClears

====
