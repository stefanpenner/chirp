---- MODULE SpellMode ----
(*
  Sticky spell mode for dictation commits (Dragon / Mac-style).

  Modes: off | on
  SetOn / SetOff switch sticky mode (commands do not emit text).
  Commit records that text is emitted under the current mode
  (when on, letter tokens transform; model tracks commit count only).
  Reset starts a new hold-to-talk session (mode → off).

  Dual of SpellMode.swift + AppState spellMode / SpellTransform.
*)

EXTENDS Integers, TLC

VARIABLES
  mode,       \* "off" | "on"
  commits,    \* number of content commits this session
  lastOp      \* "none" | "setOn" | "setOff" | "commit" | "reset"

vars == <<mode, commits, lastOp>>

Modes == {"off", "on"}

TypeOK ==
  /\ mode \in Modes
  /\ commits \in 0..8
  /\ lastOp \in {"none", "setOn", "setOff", "commit", "reset"}

Init ==
  /\ mode = "off"
  /\ commits = 0
  /\ lastOp = "none"

----
SetOn ==
  /\ mode' = "on"
  /\ lastOp' = "setOn"
  /\ UNCHANGED commits

SetOff ==
  /\ mode' = "off"
  /\ lastOp' = "setOff"
  /\ UNCHANGED commits

Commit ==
  /\ commits < 8
  /\ commits' = commits + 1
  /\ lastOp' = "commit"
  /\ UNCHANGED mode

\* New hold-to-talk session
Reset ==
  /\ mode' = "off"
  /\ commits' = 0
  /\ lastOp' = "reset"

Next ==
  \/ SetOn
  \/ SetOff
  \/ Commit
  \/ Reset

Spec == Init /\ [][Next]_vars

----
\* After SetOn, mode is on
SetOnYieldsOn == lastOp = "setOn" => mode = "on"

\* After SetOff, mode is off
SetOffYieldsOff == lastOp = "setOff" => mode = "off"

\* After reset, mode is off
ResetYieldsOff == lastOp = "reset" => mode = "off"

Inv ==
  /\ TypeOK
  /\ SetOnYieldsOn
  /\ SetOffYieldsOff
  /\ ResetYieldsOff

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ResetYieldsOff

====
