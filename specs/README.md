# Chirp formal specs (TLA+)

Model-check with the `tlc` CLI:

```bash
tlc specs/SessionMachine.tla
tlc specs/TranscriberBuffer.tla
tlc specs/PeekCommit.tla
tlc specs/PipelineRebuild.tla
```

| Spec | Purpose | Swift dual |
|------|---------|------------|
| `SessionMachine` | ready / recording / transcribing lifecycle | `SessionDecision` |
| `CancelVoid` | ESC cancel voids typed text when incremental | `CancelDecision` |
| `TranscriberBuffer` | pendingAudio is decode source; empty commit keeps buffer | `DecodePolicy` |
| `PeekCommit` | stale peeks discarded via commitGen | `AppState` peek loop |
| `PipelineRebuild` | defer pipeline rebuild mid-session | `PipelineRebuildDecision` |
| `SegmentJoin` | multi-utterance separators (space vs ". ") | `SegmentJoiner` |
| `EditStack` | multi-level undo/redo + DropSuffix (delete-last-word) | `EditStack` |
| `CapsMode` | sticky caps mode + one-shot cap that | `CapsMode` / `CapsTransform` |
| `ReplaceThat` | multi-step replace: arm then next content swaps last | `ReplaceDecision` |
| `ListCounter` | session numbered-list index for next number | `SpokenListITN` |
| `ScratchUndo` | **legacy** single-level scratch (superseded by `EditStack`) | — |
| `EditCommands` | coarse length model of edit commands (see `EditStack` for stack) | `DictationCommand` |
| `ConfidenceGate` | accept/reject ASR when token log-probs exist | `ConfidenceGate` |
| `DecodeReject` | energy/silence + log-prob composite reject (Parakeet nil scores) | `DecodeReject` |
| `ClipboardCommands` | copy that / paste that vs session buffer | `DictationCommand` |
| `AdaptivePeek` | peek interval active vs idle | `DecodePolicy.peekSleepNs` |

Bait configs (`*_bait.cfg`) must **fail** — they prove the real invariants are checked.

Config path is relative to the **spec directory** (TLC’s cwd), not the repo root:

```bash
# real Inv must pass
tlc specs/CancelVoid.tla
tlc specs/CapsMode.tla
tlc specs/ConfidenceGate.tla
tlc specs/DecodeReject.tla
tlc specs/EditStack.tla
tlc specs/ReplaceThat.tla
tlc specs/SessionMachine.tla
tlc specs/TranscriberBuffer.tla

# bait Inv must fail (error expected)
tlc -c CancelVoid_bait.cfg specs/CancelVoid.tla
tlc -c CapsMode_bait.cfg specs/CapsMode.tla
tlc -c ConfidenceGate_bait.cfg specs/ConfidenceGate.tla
tlc -c DecodeReject_bait.cfg specs/DecodeReject.tla
tlc -c EditStack_bait.cfg specs/EditStack.tla
tlc -c ReplaceThat_bait.cfg specs/ReplaceThat.tla
tlc -c SessionMachine_bait.cfg specs/SessionMachine.tla
tlc -c TranscriberBuffer_bait.cfg specs/TranscriberBuffer.tla
```

| Bait config | Weakened claim | Real property negated |
|-------------|----------------|------------------------|
| `CancelVoid_bait` | ready may keep session text | `ReadyIsVoided` |
| `CapsMode_bait` | reset may leave non-normal mode | `ResetYieldsNormal` |
| `ConfidenceGate_bait` | no-scores may reject | `NoScoresAccept` |
| `DecodeReject_bait` | silence may accept non-empty hyp | `SilenceNonEmptyRejects` |
| `EditStack_bait` | typed length may diverge from text | `TypedMatchesText` |
| `ReplaceThat_bait` | may await with no last phrase | `AwaitNeedsLastTyped` |
| `SessionMachine_bait` | ready may not be idle | `ReadyIsIdle` |
| `TranscriberBuffer_bait` | commits never use pending | `lastCommitSrc = "none"` |

`specgen` (Go) is not used here: production is Swift. Dual-test pure gates instead.
