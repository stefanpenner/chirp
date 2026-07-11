---- MODULE VadEndpoint ----
(*
  VAD min-silence / threshold clamp for user settings.

  Dual of:
    VadSettings.clamp
    VadSettings.minSilenceRange / thresholdRange

  Grain: integer tenths of a second / hundredths of threshold.
*)

EXTENDS Integers, TLC

VARIABLES
  silenceTenths,   \* raw requested silence * 10 (e.g. 5 = 0.5s)
  thresholdCents,  \* raw threshold * 100 (e.g. 45 = 0.45)
  lastOp

vars == <<silenceTenths, thresholdCents, lastOp>>

\* Ranges dual of VadSettings (0.30...1.20 s, 0.25...0.75)
MinSilence == 3
MaxSilence == 12
MinThresh == 25
MaxThresh == 75
DefaultSilence == 6   \* 0.55 ≈ 6 tenths for model grain
DefaultThresh == 45

TypeOK ==
  /\ silenceTenths \in MinSilence..MaxSilence
  /\ thresholdCents \in MinThresh..MaxThresh
  /\ lastOp \in {"init", "setSilence", "setThresh"}

Init ==
  /\ silenceTenths = DefaultSilence
  /\ thresholdCents = DefaultThresh
  /\ lastOp = "init"

----
\* User sets silence; always lands in range (clamp)
SetSilence ==
  /\ \E raw \in 0..20:
       /\ silenceTenths' =
            IF raw < MinSilence THEN MinSilence
            ELSE IF raw > MaxSilence THEN MaxSilence
            ELSE raw
       /\ lastOp' = "setSilence"
       /\ UNCHANGED thresholdCents

SetThresh ==
  /\ \E raw \in 0..100:
       /\ thresholdCents' =
            IF raw < MinThresh THEN MinThresh
            ELSE IF raw > MaxThresh THEN MaxThresh
            ELSE raw
       /\ lastOp' = "setThresh"
       /\ UNCHANGED silenceTenths

Next ==
  \/ SetSilence
  \/ SetThresh

Spec == Init /\ [][Next]_vars

----
InRange ==
  /\ silenceTenths >= MinSilence
  /\ silenceTenths <= MaxSilence
  /\ thresholdCents >= MinThresh
  /\ thresholdCents <= MaxThresh

Inv ==
  /\ TypeOK
  /\ InRange

BaitInv == ~InRange

====
