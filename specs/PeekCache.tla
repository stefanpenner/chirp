---- MODULE PeekCache ----
(*
  Skip peek ASR when pending sample count is unchanged.

  Dual: DecodePolicy.shouldReusePeek + Transcriber peek cache.
  Commit / flush / reset clear the cache (lastCount := -1).
*)

EXTENDS Integers, TLC

VARIABLES
  lastCount,     \* cached pending count; -1 = no cache
  currentCount,  \* abstract pending sample length
  lastAction     \* "init" | "grow" | "decode" | "reuse" | "commit"

vars == <<lastCount, currentCount, lastAction>>

MaxCount == 5

TypeOK ==
  /\ lastCount \in -1..MaxCount
  /\ currentCount \in 0..MaxCount
  /\ lastAction \in {"init", "grow", "decode", "reuse", "commit"}

Init ==
  /\ lastCount = -1
  /\ currentCount = 0
  /\ lastAction = "init"

----
\* Pending grows (new audio) — cache may no longer match
Grow ==
  /\ currentCount < MaxCount
  /\ currentCount' = currentCount + 1
  /\ lastAction' = "grow"
  /\ UNCHANGED lastCount

\* Real peek decode: store count; only when cache miss
Decode ==
  /\ lastCount = -1 \/ lastCount # currentCount
  /\ lastCount' = currentCount
  /\ lastAction' = "decode"
  /\ UNCHANGED currentCount

\* Reuse prior peek when counts equal and cache is live
Reuse ==
  /\ lastCount # -1
  /\ lastCount = currentCount
  /\ lastAction' = "reuse"
  /\ UNCHANGED <<lastCount, currentCount>>

\* Commit / flush / reset: clear pending + cache
Commit ==
  /\ lastCount' = -1
  /\ currentCount' = 0
  /\ lastAction' = "commit"

Next ==
  \/ Grow
  \/ Decode
  \/ Reuse
  \/ Commit

Spec == Init /\ [][Next]_vars

----
\* Reuse step only when counts equal (and cache live)
ReuseImpliesEqual ==
  lastAction = "reuse" => (lastCount # -1 /\ lastCount = currentCount)

\* Decode always installs a live cache at the current count
DecodeInstallsCache ==
  lastAction = "decode" => lastCount = currentCount

\* Commit clears cache
CommitClears ==
  lastAction = "commit" => lastCount = -1

Inv ==
  /\ TypeOK
  /\ ReuseImpliesEqual
  /\ DecodeInstallsCache
  /\ CommitClears

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~ReuseImpliesEqual

StateConstraint ==
  /\ currentCount <= MaxCount
  /\ lastCount <= MaxCount

====
