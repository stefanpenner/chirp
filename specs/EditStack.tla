---- MODULE EditStack ----
(*
  Multi-level undo/redo for typed dictation deltas (Dragon-style).

  Mirrors Sources/Chirp/EditStack.swift + AppState.performScratchThat /
  performRedoThat.

  Model: each stack entry is a positive length (delta size).
  textLen = sum of undo stack lengths (committed text still present).
  Incremental mode: typedToApp mirrors textLen after every action.
*)

EXTENDS Integers, Sequences, TLC

CONSTANTS MaxDepth, MaxLen, MaxItem

VARIABLES
  undo,      \* Seq of positive Int (delta lengths), head = oldest
  redo,      \* Seq of positive Int
  textLen,
  typedToApp

vars == <<undo, redo, textLen, typedToApp>>

TypeOK ==
  /\ undo \in Seq(1..MaxItem)
  /\ redo \in Seq(1..MaxItem)
  /\ Len(undo) <= MaxDepth
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
\* Commit delta of size n: push undo, clear redo
Commit(n) ==
  /\ n \in 1..MaxItem
  /\ textLen + n <= MaxLen
  /\ textLen' = textLen + n
  /\ typedToApp' = typedToApp + n
  /\ undo' =
       IF Len(undo) < MaxDepth
       THEN Append(undo, n)
       ELSE Append(Tail(undo), n)  \* drop oldest when over maxDepth
  /\ redo' = <<>>

\* Scratch that: undo last delta if any
Scratch ==
  /\ Len(undo) > 0
  /\ LET n == undo[Len(undo)]
     IN /\ textLen' = textLen - n
        /\ typedToApp' = typedToApp - n
        /\ undo' = SubSeq(undo, 1, Len(undo) - 1)
        /\ redo' = Append(redo, n)

ScratchEmpty ==
  /\ Len(undo) = 0
  /\ UNCHANGED vars

\* Redo that: re-apply last scratched delta
Redo ==
  /\ Len(redo) > 0
  /\ LET n == redo[Len(redo)]
     IN /\ textLen + n <= MaxLen
        /\ textLen' = textLen + n
        /\ typedToApp' = typedToApp + n
        /\ redo' = SubSeq(redo, 1, Len(redo) - 1)
        /\ undo' =
             IF Len(undo) < MaxDepth
             THEN Append(undo, n)
             ELSE Append(Tail(undo), n)

RedoEmpty ==
  /\ Len(redo) = 0
  /\ UNCHANGED vars

\* clearAll / session reset — wipe both stacks
Wipe ==
  /\ textLen > 0
  /\ textLen' = 0
  /\ typedToApp' = 0
  /\ undo' = <<>>
  /\ redo' = <<>>

\* delete last word: drop a positive suffix length from text + undo stack.
\* Models the happy path where the top delta fully covers the suffix
\* (top >= k and we shrink or pop). redo becomes <<k>>.
DropSuffix(k) ==
  /\ k \in 1..MaxItem
  /\ Len(undo) > 0
  /\ LET top == undo[Len(undo)]
     IN /\ top >= k
        /\ textLen >= k
        /\ textLen' = textLen - k
        /\ typedToApp' = typedToApp - k
        /\ redo' = <<k>>
        /\ IF top = k
           THEN undo' = SubSeq(undo, 1, Len(undo) - 1)
           ELSE undo' = SubSeq(undo, 1, Len(undo) - 1) \o <<top - k>>

\* New session
Reset ==
  /\ undo' = <<>>
  /\ redo' = <<>>
  /\ textLen' = 0
  /\ typedToApp' = 0

Next ==
  \/ \E n \in 1..MaxItem: Commit(n)
  \/ Scratch
  \/ ScratchEmpty
  \/ Redo
  \/ RedoEmpty
  \/ Wipe
  \/ \E k \in 1..MaxItem: DropSuffix(k)
  \/ Reset

Spec == Init /\ [][Next]_vars

----
Inv ==
  /\ TypeOK
  /\ typedToApp = textLen
  \* After MaxDepth overflow, oldest deltas leave the stack but stay in text.
  /\ SumSeq(undo) <= textLen
  /\ Len(undo) <= MaxDepth

StateConstraint ==
  /\ textLen <= MaxLen
  /\ Len(undo) <= MaxDepth
  /\ Len(redo) <= MaxDepth + MaxLen

====
