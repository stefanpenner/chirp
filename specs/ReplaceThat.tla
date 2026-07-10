---- MODULE ReplaceThat ----
(*
  Multi-step "replace that": arm replacement, then next content
  undoes the last phrase and inserts the new one.

  Unlike immediate scratch, text stays visible until the replacement
  phrase arrives (SOTA hold-to-talk correction UX).

  Dual of AppState.awaitingReplace + performArmReplace / content path.
*)

EXTENDS Integers, TLC

VARIABLES
  textLen,          \* length of session transcript
  lastTyped,        \* size of last content delta (0 if none)
  awaiting,         \* TRUE after "replace that", before next content
  typedToApp        \* characters sent to app (incremental)

vars == <<textLen, lastTyped, awaiting, typedToApp>>

MaxLen == 10

TypeOK ==
  /\ textLen \in 0..MaxLen
  /\ lastTyped \in 0..MaxLen
  /\ lastTyped <= textLen
  /\ awaiting \in BOOLEAN
  /\ typedToApp \in 0..MaxLen
  /\ typedToApp = textLen

Init ==
  /\ textLen = 0
  /\ lastTyped = 0
  /\ awaiting = FALSE
  /\ typedToApp = 0

----
\* Commit content of size n (normal dictation)
Commit(n) ==
  /\ ~awaiting
  /\ n \in 1..MaxLen
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ lastTyped' = n
  /\ typedToApp' = typedToApp + n
  /\ UNCHANGED awaiting

\* Arm replace when there is a last phrase
ArmReplace ==
  /\ lastTyped > 0
  /\ ~awaiting
  /\ awaiting' = TRUE
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

\* Arm with nothing to replace — no-op
ArmEmpty ==
  /\ lastTyped = 0
  /\ UNCHANGED vars

\* Next content while awaiting: drop lastTyped, append n
ReplaceCommit(n) ==
  /\ awaiting
  /\ n \in 1..MaxLen
  /\ LET base == textLen - lastTyped
     IN /\ base + n <= MaxLen
        /\ textLen' = base + n
        /\ typedToApp' = base + n
        /\ lastTyped' = n
        /\ awaiting' = FALSE

\* Immediate scratch undoes last and cancels await
Scratch ==
  /\ lastTyped > 0
  /\ textLen' = textLen - lastTyped
  /\ typedToApp' = typedToApp - lastTyped
  /\ lastTyped' = 0
  /\ awaiting' = FALSE

ScratchEmpty ==
  /\ lastTyped = 0
  /\ UNCHANGED vars

\* Cancel await without undoing (e.g. session end) — optional explicit cancel
CancelAwait ==
  /\ awaiting
  /\ awaiting' = FALSE
  /\ UNCHANGED <<textLen, lastTyped, typedToApp>>

Reset ==
  /\ textLen' = 0
  /\ lastTyped' = 0
  /\ awaiting' = FALSE
  /\ typedToApp' = 0

Next ==
  \/ \E n \in 1..MaxLen: Commit(n)
  \/ ArmReplace
  \/ ArmEmpty
  \/ \E n \in 1..MaxLen: ReplaceCommit(n)
  \/ Scratch
  \/ ScratchEmpty
  \/ CancelAwait
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ typedToApp = textLen
  /\ lastTyped <= textLen
  \* Cannot await when nothing was typed
  /\ awaiting => lastTyped > 0

StateConstraint == textLen <= MaxLen

====
