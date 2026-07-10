---- MODULE CapsMode ----
(*
  Sticky capitalization mode for dictation commits (Dragon-style).

  Modes: normal | noCaps | allCaps | capsOn
  SetMode switches sticky mode (commands do not emit text).
  Commit records that text is emitted under the current mode.
  CapThat is a one-shot transform of prior text (mode unchanged).

  Dual of CapsMode.swift + AppState capsMode / CapsTransform.
*)

EXTENDS Integers, TLC

VARIABLES
  mode,       \* "normal" | "noCaps" | "allCaps" | "capsOn"
  commits,    \* number of content commits this session
  lastOp      \* "none" | "set" | "commit" | "capThat" | "reset"

vars == <<mode, commits, lastOp>>

Modes == {"normal", "noCaps", "allCaps", "capsOn"}

TypeOK ==
  /\ mode \in Modes
  /\ commits \in 0..8
  /\ lastOp \in {"none", "set", "commit", "capThat", "reset"}

Init ==
  /\ mode = "normal"
  /\ commits = 0
  /\ lastOp = "none"

----
SetMode(m) ==
  /\ m \in Modes
  /\ mode' = m
  /\ lastOp' = "set"
  /\ UNCHANGED commits

Commit ==
  /\ commits < 8
  /\ commits' = commits + 1
  /\ lastOp' = "commit"
  /\ UNCHANGED mode

\* One-shot transform of already-committed text (cap that / title case that);
\* requires prior content. Mode unchanged.
CapThat ==
  /\ commits > 0
  /\ lastOp' = "capThat"
  /\ UNCHANGED <<mode, commits>>

\* New hold-to-talk session
Reset ==
  /\ mode' = "normal"
  /\ commits' = 0
  /\ lastOp' = "reset"

Next ==
  \/ \E m \in Modes: SetMode(m)
  \/ Commit
  \/ CapThat
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* After reset, mode is normal (enforced by Reset action)
ResetYieldsNormal == lastOp = "reset" => mode = "normal"

\* CapThat never fires without prior commits (enforced by guard)
CapThatNeedsContent == lastOp = "capThat" => commits > 0

Inv ==
  /\ TypeOK
  /\ ResetYieldsNormal
  /\ CapThatNeedsContent

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ResetYieldsNormal

====
