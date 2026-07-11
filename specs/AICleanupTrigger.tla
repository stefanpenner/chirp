---- MODULE AICleanupTrigger ----
(*
  On-demand AI cleanup triggers (hold-to-talk + C, menu, spoken).

  Dual of:
    AICleanupTriggerDecision
    HotkeyManager hold-chord (fnDown + C)
    AppState.runAICleanup / isCleaningUp

  Grain:
    holdActive  — hold-to-talk key is down
    hasText     — session buffer non-empty
    cleaning    — cleanup in flight
    lastOp

  Product:
    - Hold + C starts cleanup when hasText and not already cleaning
    - Menu / spoken modeled as same StartCleanup action
    - Cannot re-enter cleaning while cleaning
    - CleanupDone returns to non-cleaning (hold may still be down)
    - Hold release does not cancel in-flight cleanup (async task)
*)

EXTENDS Integers, TLC

VARIABLES
  holdActive,
  hasText,
  cleaning,
  lastOp   \* "none" | "hold" | "release" | "commit" | "chord" | "menu" | "done" | "busy"

vars == <<holdActive, hasText, cleaning, lastOp>>

TypeOK ==
  /\ holdActive \in BOOLEAN
  /\ hasText \in BOOLEAN
  /\ cleaning \in BOOLEAN
  /\ lastOp \in {"none", "hold", "release", "commit", "chord", "menu", "done", "busy"}

Init ==
  /\ holdActive = FALSE
  /\ hasText = FALSE
  /\ cleaning = FALSE
  /\ lastOp = "none"

----
HoldDown ==
  /\ ~holdActive
  /\ holdActive' = TRUE
  /\ lastOp' = "hold"
  /\ UNCHANGED <<hasText, cleaning>>

HoldUp ==
  /\ holdActive
  /\ holdActive' = FALSE
  /\ lastOp' = "release"
  /\ UNCHANGED <<hasText, cleaning>>

\* Dictation commit while held (or after) yields text
CommitText ==
  /\ hasText' = TRUE
  /\ lastOp' = "commit"
  /\ UNCHANGED <<holdActive, cleaning>>

\* Hold + C chord (requires holdActive)
HoldChordCleanup ==
  /\ holdActive
  /\ hasText
  /\ ~cleaning
  /\ cleaning' = TRUE
  /\ lastOp' = "chord"
  /\ UNCHANGED <<holdActive, hasText>>

\* Chord while already cleaning — busy no-op
HoldChordBusy ==
  /\ holdActive
  /\ cleaning
  /\ lastOp' = "busy"
  /\ UNCHANGED <<holdActive, hasText, cleaning>>

\* Chord with no text — no-op (still records lastOp busy-like miss as busy)
HoldChordNoText ==
  /\ holdActive
  /\ ~hasText
  /\ ~cleaning
  /\ lastOp' = "busy"
  /\ UNCHANGED <<holdActive, hasText, cleaning>>

\* Menu / spoken / ⌘⇧U — same start gate (no hold required)
MenuCleanup ==
  /\ hasText
  /\ ~cleaning
  /\ cleaning' = TRUE
  /\ lastOp' = "menu"
  /\ UNCHANGED <<holdActive, hasText>>

CleanupDone ==
  /\ cleaning
  /\ cleaning' = FALSE
  /\ lastOp' = "done"
  /\ UNCHANGED <<holdActive, hasText>>

Next ==
  \/ HoldDown
  \/ HoldUp
  \/ CommitText
  \/ HoldChordCleanup
  \/ HoldChordBusy
  \/ HoldChordNoText
  \/ MenuCleanup
  \/ CleanupDone

Spec == Init /\ [][Next]_vars

----
\* Cleaning implies we had a successful start (hasText was true at start;
\* may still be true after). Stronger: never cleaning without hasText.
CleaningImpliesText ==
  cleaning => hasText

\* Chord start always leaves cleaning true
ChordStartsCleaning ==
  lastOp = "chord" => cleaning

Inv ==
  /\ TypeOK
  /\ CleaningImpliesText
  /\ ChordStartsCleaning

BaitInv == ~CleaningImpliesText

====
