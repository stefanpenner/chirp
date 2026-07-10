---- MODULE FormatCommands ----
(*
  Spoken format commands (bold / italic / underline that) and selection
  collapse.

  Purpose: prove the format path ends with selection collapsed so the next
  typed character does not replace selected text.

  After select-last + format, hasSelection must be FALSE (product always
  clearSelection after format — dual: AppState.performFormatThat).

  No Swift codegen; TLA alone documents the collapse contract.
*)

EXTENDS Integers, TLC

VARIABLES
  hasSelection,   \* TRUE when app selection is non-empty (session-driven)
  phase,          \* "idle" | "selected" | "formatted"
  textNonEmpty    \* TRUE when session has text that can be selected

vars == <<hasSelection, phase, textNonEmpty>>

Phases == {"idle", "selected", "formatted"}

TypeOK ==
  /\ hasSelection \in BOOLEAN
  /\ phase \in Phases
  /\ textNonEmpty \in BOOLEAN

Init ==
  /\ hasSelection = FALSE
  /\ phase = "idle"
  /\ textNonEmpty = FALSE

----
\* Content arrives (dictation commit) — establishes non-empty text, caret only
Type ==
  /\ textNonEmpty' = TRUE
  /\ hasSelection' = FALSE
  /\ phase' = "idle"

\* Select last phrase / last word (performSelectThat / selectBackward)
SelectLast ==
  /\ textNonEmpty
  /\ hasSelection' = TRUE
  /\ phase' = "selected"
  /\ UNCHANGED textNonEmpty

\* Format while session has a selection — apply then collapse
Format ==
  /\ hasSelection
  /\ hasSelection' = FALSE
  /\ phase' = "formatted"
  /\ UNCHANGED textNonEmpty

\* Format with no session selection (still format app selection / caret)
\* Product always clearSelection after format; already collapsed here.
FormatNoSelect ==
  /\ ~hasSelection
  /\ hasSelection' = FALSE
  /\ phase' = "formatted"
  /\ UNCHANGED textNonEmpty

\* Explicit unselect / move caret without formatting
Unselect ==
  /\ hasSelection
  /\ hasSelection' = FALSE
  /\ phase' = "idle"
  /\ UNCHANGED textNonEmpty

\* Type while selected replaces selection (danger if format forgot to collapse)
TypeWhileSelected ==
  /\ hasSelection
  /\ hasSelection' = FALSE
  /\ phase' = "idle"
  /\ textNonEmpty' = TRUE

\* Clear session text
Clear ==
  /\ textNonEmpty
  /\ textNonEmpty' = FALSE
  /\ hasSelection' = FALSE
  /\ phase' = "idle"

Next ==
  \/ Type
  \/ SelectLast
  \/ Format
  \/ FormatNoSelect
  \/ Unselect
  \/ TypeWhileSelected
  \/ Clear

Spec == Init /\ [][Next]_vars

----
\* After any format step, selection is collapsed
FormatImpliesCollapsed ==
  phase = "formatted" => ~hasSelection

\* selected phase always has a selection; idle/formatted never do
PhaseSelectionCoupling ==
  /\ phase = "selected" <=> hasSelection
  /\ phase = "formatted" => ~hasSelection
  /\ phase = "idle" => ~hasSelection

\* Cannot select empty session text (guard of SelectLast)
SelectionNeedsText ==
  hasSelection => textNonEmpty

Inv ==
  /\ TypeOK
  /\ FormatImpliesCollapsed
  /\ PhaseSelectionCoupling
  /\ SelectionNeedsText

\* Bait: negation of a real safety property (must FAIL under TLC)
BaitInv == ~FormatImpliesCollapsed

====
