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
| `SpellMode` | sticky spell mode (letter packing) | `SpellMode` / `SpellTransform` |
| `ReplaceThat` | multi-step replace: arm then next content swaps last | `ReplaceDecision` |
| `ListCounter` | session numbered-list index for next number | `SpokenListITN` |
| `ScratchUndo` | **legacy / no bait** single-level scratch (superseded by `EditStack`) | — |
| `EditCommands` | coarse length model of edit commands (see `EditStack` for stack) | `DictationCommand` |
| `ConfidenceGate` | length-aware accept/reject when token log-probs exist | `ConfidenceGate` |
| `DecodeReject` | energy/silence + log-prob composite reject (Parakeet nil scores) | `DecodeReject` |
| `ClipboardCommands` | copy that / paste that vs session buffer | `DictationCommand` |
| `FormatCommands` | format path collapses selection so next type does not replace | `AppState.performFormatThat` + clearSelection |
| `TranscriptSelection` | last-sentence / last-paragraph lengths ≤ total buffer | `TranscriptSelection` + select last sentence/para |
| `AdaptivePeek` | peek interval active vs idle | `DecodePolicy.peekSleepNs` |
| `PeekCache` | skip peek ASR when pending count unchanged | `DecodePolicy.shouldReusePeek` |

Bait configs (`*_bait.cfg`) must **fail** — they prove the real invariants are checked.

Config path is relative to the **spec directory** (TLC’s cwd), not the repo root:

```bash
# real Inv must pass
tlc specs/AdaptivePeek.tla
tlc specs/PeekCache.tla
tlc specs/CancelVoid.tla
tlc specs/CapsMode.tla
tlc specs/ClipboardCommands.tla
tlc specs/SpellMode.tla
tlc specs/ConfidenceGate.tla
tlc specs/DecodeReject.tla
tlc specs/EditCommands.tla
tlc specs/EditStack.tla
tlc specs/FormatCommands.tla
tlc specs/TranscriptSelection.tla
tlc specs/ListCounter.tla
tlc specs/PeekCommit.tla
tlc specs/PipelineRebuild.tla
tlc specs/ReplaceThat.tla
tlc specs/SegmentJoin.tla
tlc specs/SessionMachine.tla
tlc specs/TranscriberBuffer.tla

# bait Inv must fail (error expected)
tlc -c AdaptivePeek_bait.cfg specs/AdaptivePeek.tla
tlc -c PeekCache_bait.cfg specs/PeekCache.tla
tlc -c CancelVoid_bait.cfg specs/CancelVoid.tla
tlc -c CapsMode_bait.cfg specs/CapsMode.tla
tlc -c ClipboardCommands_bait.cfg specs/ClipboardCommands.tla
tlc -c SpellMode_bait.cfg specs/SpellMode.tla
tlc -c ConfidenceGate_bait.cfg specs/ConfidenceGate.tla
tlc -c DecodeReject_bait.cfg specs/DecodeReject.tla
tlc -c EditCommands_bait.cfg specs/EditCommands.tla
tlc -c EditStack_bait.cfg specs/EditStack.tla
tlc -c FormatCommands_bait.cfg specs/FormatCommands.tla
tlc -c TranscriptSelection_bait.cfg specs/TranscriptSelection.tla
tlc -c ListCounter_bait.cfg specs/ListCounter.tla
tlc -c PeekCommit_bait.cfg specs/PeekCommit.tla
tlc -c PipelineRebuild_bait.cfg specs/PipelineRebuild.tla
tlc -c ReplaceThat_bait.cfg specs/ReplaceThat.tla
tlc -c SegmentJoin_bait.cfg specs/SegmentJoin.tla
tlc -c SessionMachine_bait.cfg specs/SessionMachine.tla
tlc -c TranscriberBuffer_bait.cfg specs/TranscriberBuffer.tla
```

| Bait config | Weakened claim | Real property negated |
|-------------|----------------|------------------------|
| `AdaptivePeek_bait` | idle interval may appear before threshold misses | `IdleImpliesMisses` |
| `PeekCache_bait` | reuse may leave lastCount ≠ currentCount | `ReuseImpliesEqual` |
| `CancelVoid_bait` | ready may keep session text | `ReadyIsVoided` |
| `CapsMode_bait` | reset may leave non-normal mode | `ResetYieldsNormal` |
| `ClipboardCommands_bait` | copy may leave clip ≠ transcript | `CopyMirrors` |
| `SpellMode_bait` | reset may leave spell on | `ResetYieldsOff` |
| `ConfidenceGate_bait` | no-scores may reject | `NoScoresAccept` |
| `DecodeReject_bait` | silence may accept non-empty hyp | `SilenceNonEmptyRejects` |
| `EditCommands_bait` | lastTyped may exceed textLen | `LastTypedWithinText` |
| `EditStack_bait` | typed length may diverge from text | `TypedMatchesText` |
| `FormatCommands_bait` | format may leave selection active | `FormatImpliesCollapsed` |
| `TranscriptSelection_bait` | last segment may exceed total | `LastWithinTotal` |
| `ListCounter_bait` | end/reset may leave n ≠ 1 | `EndOrResetYieldsOne` |
| `PeekCommit_bait` | speculative text may appear while idle | `SpecOnlyWhileRecording` |
| `PipelineRebuild_bait` | type bounds may fail | `TypeOK` |
| `ReplaceThat_bait` | may await with no last phrase | `AwaitNeedsLastTyped` |
| `SegmentJoin_bait` | sentence sep may appear with no text | `SentenceImpliesContext` |
| `SessionMachine_bait` | ready may not be idle | `ReadyIsIdle` |
| `TranscriberBuffer_bait` | commits never use pending | `lastCommitSrc = "none"` |

`specgen` (Go) is not used here: production is Swift. Dual-test pure gates instead.
