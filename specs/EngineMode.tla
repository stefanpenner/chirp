---- MODULE EngineMode ----
(*
  Transcription / STT engine mode selection + availability fallback.

  Purpose:
    - default active engine is offline (Parakeet/sherpa CPU)
    - optional engines (systemSpeech, fluidAudio) only activate when available
    - unavailable desired mode resolves to offline (never stuck on dead engine)
    - mid-session desired changes set needsRebuild; active stays until idle apply
      (orthogonal detail of rebuild: PipelineRebuild.tla)

  Product dual: EngineModeDecision.swift + AppState.rebuildPipeline resolve.
  FluidAudio: modeled as optional mode; product currently fluidOk=FALSE always
  (deferred — Bazel/SPM packaging). TLC still proves fallback safety.
*)

EXTENDS Integers, TLC

VARIABLES
  desired,       \* user-selected mode
  active,        \* resolved engine actually driving the pipeline
  sessionActive, \* BOOL: recording | transcribing (coarse)
  needsRebuild,  \* deferred apply of desired → active
  systemOk,      \* Apple SpeechAnalyzer available
  fluidOk,       \* FluidAudio ANE path available (product: always FALSE today)
  applyCount     \* lid: how many times active was applied (TLC tiny)

\* Lid — product may switch modes unbounded; TLC keeps domain tiny.
MaxApply == 3

ModeSet == {"offline", "cloud", "system", "fluid"}

vars == <<desired, active, sessionActive, needsRebuild, systemOk, fluidOk, applyCount>>

TypeOK ==
  /\ desired \in ModeSet
  /\ active \in ModeSet
  /\ sessionActive \in BOOLEAN
  /\ needsRebuild \in BOOLEAN
  /\ systemOk \in BOOLEAN
  /\ fluidOk \in BOOLEAN
  /\ applyCount \in 0..MaxApply

\* Resolve desired against availability — offline/cloud always ok.
Resolved(d, sys, flu) ==
  IF d = "offline" THEN "offline"
  ELSE IF d = "cloud" THEN "cloud"
  ELSE IF d = "system" THEN IF sys THEN "system" ELSE "offline"
  ELSE IF d = "fluid" THEN IF flu THEN "fluid" ELSE "offline"
  ELSE "offline"

Init ==
  /\ desired = "offline"
  /\ active = "offline"
  /\ sessionActive = FALSE
  /\ needsRebuild = FALSE
  /\ systemOk = FALSE
  /\ fluidOk = FALSE
  /\ applyCount = 0

----
\* Idle: select mode and apply resolve immediately
SelectIdle(m) ==
  /\ ~sessionActive
  /\ m \in ModeSet
  /\ applyCount < MaxApply
  /\ desired' = m
  /\ active' = Resolved(m, systemOk, fluidOk)
  /\ needsRebuild' = FALSE
  /\ applyCount' = applyCount + 1
  /\ UNCHANGED <<sessionActive, systemOk, fluidOk>>

\* Mid-session: only record desired; active frozen
SelectActive(m) ==
  /\ sessionActive
  /\ m \in ModeSet
  /\ desired' = m
  /\ needsRebuild' = TRUE
  /\ UNCHANGED <<active, sessionActive, systemOk, fluidOk, applyCount>>

StartSession ==
  /\ ~sessionActive
  /\ sessionActive' = TRUE
  /\ UNCHANGED <<desired, active, needsRebuild, systemOk, fluidOk, applyCount>>

EndSession ==
  /\ sessionActive
  /\ sessionActive' = FALSE
  /\ UNCHANGED <<desired, active, needsRebuild, systemOk, fluidOk, applyCount>>

\* Apply deferred rebuild when idle
ApplyDeferred ==
  /\ ~sessionActive
  /\ needsRebuild
  /\ applyCount < MaxApply
  /\ active' = Resolved(desired, systemOk, fluidOk)
  /\ needsRebuild' = FALSE
  /\ applyCount' = applyCount + 1
  /\ UNCHANGED <<desired, sessionActive, systemOk, fluidOk>>

\* Availability flips (OS assets / future Fluid link)
SetSystemOk(b) ==
  /\ systemOk' = b
  /\ needsRebuild' = TRUE   \* re-resolve when safe
  /\ UNCHANGED <<desired, active, sessionActive, fluidOk, applyCount>>

SetFluidOk(b) ==
  /\ fluidOk' = b
  /\ needsRebuild' = TRUE
  /\ UNCHANGED <<desired, active, sessionActive, systemOk, applyCount>>

Next ==
  \/ \E m \in ModeSet: SelectIdle(m)
  \/ \E m \in ModeSet: SelectActive(m)
  \/ StartSession
  \/ EndSession
  \/ ApplyDeferred
  \/ \E b \in BOOLEAN: SetSystemOk(b)
  \/ \E b \in BOOLEAN: SetFluidOk(b)

Spec == Init /\ [][Next]_vars

----
\* Safety

\* When stable (no deferred rebuild), active is legal under current availability.
\* Availability can drop with needsRebuild set before ApplyDeferred re-resolves —
\* that window is intentional (mid-session freeze of the live pipeline).
ActiveLegalWhenStable ==
  ~needsRebuild =>
    /\ (active = "system" => systemOk)
    /\ (active = "fluid" => fluidOk)

\* Idle + no pending rebuild ⇒ active matches resolve(desired)
IdleConsistent ==
  (/\ ~sessionActive /\ ~needsRebuild)
    => active = Resolved(desired, systemOk, fluidOk)

StateConstraint ==
  applyCount <= MaxApply

Inv ==
  /\ TypeOK
  /\ ActiveLegalWhenStable
  /\ IdleConsistent

\* Bait: negation of stable legality — must FAIL under TLC
BaitInv == ~ActiveLegalWhenStable

====
