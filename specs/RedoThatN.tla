---- MODULE RedoThatN ----
(*
  Dragon "redo that N times": re-apply up to N scratched segments in one utterance.

  Mirrors Sources/Chirp performRedoThat(count:) + ScratchThatDecision.plan
  applied to the redo stack (oldest first).

  Model: redo stack entries are positive lengths (oldest first).
  Redoing peels from the top (newest) up to min(N, Len(redo)).
*)

EXTENDS Integers, Sequences, TLC

CONSTANTS MaxDepth, MaxLen, MaxItem, MaxN

VARIABLES
  undo,      \* Seq of positive Int, head = oldest
  redo,      \* Seq of positive Int, head = oldest
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

Init ==
  /\ undo = <<>>
  /\ redo = <<>>
  /\ textLen = 0
  /\ typedToApp = 0

----
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

\* Scratch one (feeds redo)
Scratch ==
  /\ Len(undo) > 0
  /\ LET n == undo[Len(undo)]
     IN /\ textLen' = textLen - n
        /\ typedToApp' = typedToApp - n
        /\ undo' = SubSeq(undo, 1, Len(undo) - 1)
        /\ redo' = Append(redo, n)

\* Peel up to k newest from redo onto undo (same shape as ScratchThatN.Peel)
PeelRedo(k, u, r) ==
  LET RECURSIVE Go(_, _, _, _)
      Go(left, uu, rr, sum) ==
        IF left = 0 \/ rr = <<>>
        THEN <<uu, rr, sum>>
        ELSE
          LET top == rr[Len(rr)]
              rr2 == SubSeq(rr, 1, Len(rr) - 1)
              uu2 ==
                IF Len(uu) < MaxDepth
                THEN Append(uu, top)
                ELSE Append(Tail(uu), top)
          IN Go(left - 1, uu2, rr2, sum + top)
  IN Go(k, u, r, 0)

\* Redo that N times. No-op when redo empty. Reject if would exceed MaxLen.
RedoN(k) ==
  /\ k \in 1..MaxN
  /\ IF Len(redo) = 0
     THEN UNCHANGED vars
     ELSE
       LET p == PeelRedo(k, undo, redo)
           uu == p[1]
           rr == p[2]
           peeled == p[3]
       IN /\ textLen + peeled <= MaxLen
          /\ textLen' = textLen + peeled
          /\ typedToApp' = typedToApp + peeled
          /\ undo' = uu
          /\ redo' = rr

Reset ==
  /\ undo' = <<>>
  /\ redo' = <<>>
  /\ textLen' = 0
  /\ typedToApp' = 0

Next ==
  \/ \E n \in 1..MaxItem: Commit(n)
  \/ Scratch
  \/ \E k \in 1..MaxN: RedoN(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ SumSeq(undo) <= textLen
  /\ Len(undo) <= MaxDepth

BaitInv == ~TypeOK

StateConstraint ==
  /\ textLen <= MaxLen
  /\ Len(undo) <= MaxDepth

====
