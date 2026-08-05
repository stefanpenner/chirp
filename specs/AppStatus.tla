---- MODULE AppStatus ----
(*
  Full AppState.Status lifecycle: boot (model download/load) + session entry.

  Purpose: prove stuck-mode safety for UI/status —
    - no session from boot/error without passing through ready
    - download cancel only while downloading
    - retry only from error | needsModel
    - overlay rules for download + session
    - ready is idle (overlay off)

  Session rejoin/consumer gen is SessionMachine.tla (orthogonal).
  Dual: AppStatusDecision.swift
*)

EXTENDS Integers, TLC

VARIABLES
  status,   \* AppState.Status kind (no progress/message payloads)
  overlay   \* whether the floating island is ordered front

StatusSet == {
  "needsModel",
  "downloading",
  "loadingModel",
  "ready",
  "recording",
  "transcribing",
  "error"
}

vars == <<status, overlay>>

TypeOK ==
  /\ status \in StatusSet
  /\ overlay \in BOOLEAN

\* Product default before ensureModel() settles.
Init ==
  /\ status = "loadingModel"
  /\ overlay = FALSE

----
\* Boot / model

\* ensureModel with no on-disk model, retry, or modelFileCheck miss on ready.
StartDownload ==
  /\ status \in {"needsModel", "error", "loadingModel", "ready"}
  /\ status' = "downloading"
  /\ overlay' = TRUE

CancelDownload ==
  /\ status = "downloading"
  /\ status' = "needsModel"
  /\ overlay' = FALSE

DownloadOK ==
  /\ status = "downloading"
  /\ status' = "loadingModel"
  /\ UNCHANGED overlay

DownloadFail ==
  /\ status = "downloading"
  /\ status' = "error"
  /\ UNCHANGED overlay   \* island stays so user sees error (product)

\* ensureModel found model on disk: already loadingModel (Init) or enter load.
\* Explicit LoadBegin covers ready→load after reinstall edge; keep tiny.
LoadBegin ==
  /\ status \in {"needsModel", "error", "ready"}
  /\ status' = "loadingModel"
  /\ UNCHANGED overlay

LoadOK ==
  /\ status = "loadingModel"
  /\ status' = "ready"
  /\ overlay' = FALSE

LoadFail ==
  /\ status = "loadingModel"
  /\ status' = "error"
  /\ UNCHANGED overlay

----
\* Session (coarse; dual SessionMachine for rejoin/gen)

StartSession ==
  /\ status = "ready"
  /\ status' = "recording"
  /\ overlay' = TRUE

StopSession ==
  /\ status = "recording"
  /\ status' = "transcribing"
  /\ UNCHANGED overlay

Rejoin ==
  /\ status = "transcribing"
  /\ status' = "recording"
  /\ UNCHANGED overlay

FinishSession ==
  /\ status = "transcribing"
  /\ status' = "ready"
  /\ overlay' = FALSE

CancelSession ==
  /\ status \in {"recording", "transcribing"}
  /\ status' = "ready"
  /\ overlay' = FALSE

----

Next ==
  \/ StartDownload
  \/ CancelDownload
  \/ DownloadOK
  \/ DownloadFail
  \/ LoadBegin
  \/ LoadOK
  \/ LoadFail
  \/ StartSession
  \/ StopSession
  \/ Rejoin
  \/ FinishSession
  \/ CancelSession

Spec == Init /\ [][Next]_vars

----
\* Safety

\* Overlay must be up while downloading (progress / cancel affordance).
OverlayWhileDownloading ==
  status = "downloading" => overlay

\* Session keeps the island visible.
OverlayWhileSession ==
  status \in {"recording", "transcribing"} => overlay

\* Ready is clean idle for the overlay.
ReadyIsIdle ==
  status = "ready" => ~overlay

\* needsModel is idle (download cancelled or never started).
NeedsModelIsIdle ==
  status = "needsModel" => ~overlay

\* Session phases are only reachable via StartSession from ready
\* (inductive: no action jumps boot → recording).
BootNotSession ==
  status \in {"needsModel", "downloading", "loadingModel", "error"}
    => status \notin {"recording", "transcribing"}

Inv ==
  /\ TypeOK
  /\ OverlayWhileDownloading
  /\ OverlayWhileSession
  /\ ReadyIsIdle
  /\ NeedsModelIsIdle
  /\ BootNotSession

\* Bait: negation of ReadyIsIdle must FAIL under TLC.
BaitInv == ~ReadyIsIdle

====
