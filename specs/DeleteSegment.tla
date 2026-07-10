---- MODULE DeleteSegment ----
(*
  Delete last segment (sentence / paragraph / line) as length arithmetic.

  Dual of transcript last-segment delete: total shrinks by lastSegLen.
  (Selection lengths: TranscriptSelection; word drop: EditStack DropSuffix /
  EditCommands DeleteLastWord. This spec is the coarser segment-delete lens.)

  Grain: totalLen + lastSegLen only (0..4). No strings.
*)

EXTENDS Integers, TLC

VARIABLES
  totalLen,       \* abstract buffer character count
  lastSegLen,     \* length of trailing segment (sentence / para / line)
  prevTotal,      \* totalLen before last DeleteLastSeg
  prevSeg,        \* lastSegLen before last DeleteLastSeg
  lastOp          \* "none" | "grow" | "break" | "delete" | "clear"

vars == <<totalLen, lastSegLen, prevTotal, prevSeg, lastOp>>

MaxLen == 4

TypeOK ==
  /\ totalLen \in 0..MaxLen
  /\ lastSegLen \in 0..MaxLen
  /\ prevTotal \in 0..MaxLen
  /\ prevSeg \in 0..MaxLen
  /\ lastOp \in {"none", "grow", "break", "delete", "clear"}
  /\ lastSegLen <= totalLen
  /\ totalLen >= 0

Init ==
  /\ totalLen = 0
  /\ lastSegLen = 0
  /\ prevTotal = 0
  /\ prevSeg = 0
  /\ lastOp = "none"

----
\* Extend trailing segment (no break)
Grow(n) ==
  /\ n \in 1..MaxLen
  /\ totalLen + n <= MaxLen
  /\ totalLen' = totalLen + n
  /\ lastSegLen' = lastSegLen + n
  /\ lastOp' = "grow"
  /\ UNCHANGED <<prevTotal, prevSeg>>

\* New trailing segment of length n after a break
Break(n) ==
  /\ n \in 1..MaxLen
  /\ totalLen + n <= MaxLen
  /\ totalLen' = totalLen + n
  /\ lastSegLen' = n
  /\ lastOp' = "break"
  /\ UNCHANGED <<prevTotal, prevSeg>>

\* Delete last segment: total shrinks by lastSegLen; trailing seg cleared
DeleteLastSeg ==
  /\ lastSegLen > 0
  /\ prevTotal' = totalLen
  /\ prevSeg' = lastSegLen
  /\ totalLen' = totalLen - lastSegLen
  /\ lastSegLen' = 0
  /\ lastOp' = "delete"

\* No-op when no trailing segment
DeleteEmpty ==
  /\ lastSegLen = 0
  /\ UNCHANGED vars

\* Wipe buffer
Clear ==
  /\ totalLen > 0
  /\ totalLen' = 0
  /\ lastSegLen' = 0
  /\ lastOp' = "clear"
  /\ UNCHANGED <<prevTotal, prevSeg>>

Next ==
  \/ \E n \in 1..MaxLen: Grow(n)
  \/ \E n \in 1..MaxLen: Break(n)
  \/ DeleteLastSeg
  \/ DeleteEmpty
  \/ Clear

Spec == Init /\ [][Next]_vars

----
\* Segment is always a suffix length; buffer never negative (TypeOK)
SegWithinTotal == lastSegLen <= totalLen

\* After delete: totalLen = old total - old lastSegLen; segment consumed
DeleteSubtracts ==
  lastOp = "delete" =>
    /\ totalLen = prevTotal - prevSeg
    /\ lastSegLen = 0
    /\ prevSeg > 0
    /\ totalLen >= 0

\* Empty buffer has no trailing segment
EmptyImpliesZeroSeg ==
  totalLen = 0 => lastSegLen = 0

Inv ==
  /\ TypeOK
  /\ SegWithinTotal
  /\ DeleteSubtracts
  /\ EmptyImpliesZeroSeg

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~DeleteSubtracts

StateConstraint == totalLen <= MaxLen

====
