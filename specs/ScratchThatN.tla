---- MODULE ScratchThatN ----
(*
  Dragon "scratch that N times": undo up to N typed segments in one utterance.

  Mirrors Sources/Chirp/ScratchThatDecision.swift + performScratchThat(count:).
  Single "scratch that" is ScratchN(1). Empty stack: no-op (all zeros).

  Model: undo stack entries are positive lengths (oldest first).
  Scratching peels from the top (newest) up to min(N, Len(undo)).
*)

EXTENDS Integers, Sequences, TLC

CONSTANTS MaxDepth, MaxLen, MaxItem, MaxN

VARIABLES
  undo,      \* Seq of positive Int, head = oldest
  redo,      \* Seq of positive Int
  textLen,
  typedToApp

vars == <<undo, redo, textLen, typedToApp>>

TypeOK ==
  /\ undo \in Seq(1..MaxItem)
  /\ redo \in Seq(1..MaxItem)
  /\ Len(undo) <= MaxDepth
  /\ Len(redo) <= MaxDepth + MaxLen
  /\ textLen \in 0..MaxLen
  /\ typedToApp \in 0..MaxLen
  /\ textLen = typedToApp

SumSeq(s) ==
  LET RECURSIVE Sum(_)
      Sum(seq) == IF seq = <<>> THEN 0 ELSE Head(seq) + Sum(Tail(seq))
  IN Sum(s)

Min(a, b) == IF a <= b THEN a ELSE b

Init ==
  /\ undo = <<>>
  /\ redo = <<>>
  /\ textLen = 0
  /\ typedToApp = 0

----
\* Commit one delta
Commit(n) ==
  /\ n \in 1..MaxItem
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ typedToApp' = typedToApp + n
  /\ undo' =
       IF Len(undo) < MaxDepth
       THEN Append(undo, n)
       ELSE Append(Tail(undo), n)
  /\ redo' = <<>>

\* Pure: peel up to k newest undos → (newUndo, newRedoSuffix, peeledSum)
\* newRedoSuffix is the deltas in undo order (oldest of the peeled first),
\* matching repeated undo which appends each peeled item to redo.
Peel(k, u, r) ==
  LET RECURSIVE Go(_, _, _, _)
      Go(left, uu, rr, sum) ==
        IF left = 0 \/ uu = <<>>
        THEN <<uu, rr, sum>>
        ELSE
          LET top == uu[Len(uu)]
              uu2 == SubSeq(uu, 1, Len(uu) - 1)
          IN Go(left - 1, uu2, Append(rr, top), sum + top)
  IN Go(k, u, r, 0)

\* Scratch that N times (N ≥ 1). No-op when stack empty (UNCHANGED).
ScratchN(k) ==
  /\ k \in 1..MaxN
  /\ IF Len(undo) = 0
     THEN UNCHANGED vars
     ELSE
       LET p == Peel(k, undo, redo)
           uu == p[1]
           rr == p[2]
           peeled == p[3]
       IN /\ textLen' = textLen - peeled
          /\ typedToApp' = typedToApp - peeled
          /\ undo' = uu
          /\ redo' = rr

Reset ==
  /\ undo' = <<>>
  /\ redo' = <<>>
  /\ textLen' = 0
  /\ typedToApp' = 0

Next ==
  \/ \E n \in 1..MaxItem: Commit(n)
  \/ \E k \in 1..MaxN: ScratchN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ SumSeq(undo) <= textLen
  /\ Len(undo) <= MaxDepth

\* After ScratchN(k), we never peel more than existed
\* (enforced by Peel stopping at empty).

BaitInv == ~TypeOK

StateConstraint ==
  /\ textLen <= MaxLen
  /\ Len(undo) <= MaxDepth

====
