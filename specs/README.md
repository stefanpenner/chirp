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
| `TranscriberBuffer` | pendingAudio is decode source; empty commit keeps buffer | `DecodePolicy` |
| `PeekCommit` | stale peeks discarded via commitGen | `AppState` peek loop |
| `PipelineRebuild` | defer pipeline rebuild mid-session | `PipelineRebuildDecision` |
| `SegmentJoin` | multi-utterance separators (space vs ". ") | `SegmentJoiner` |
| `ScratchUndo` | spoken "scratch that" undoes last segment | `DictationCommand` |
| `EditCommands` | scratch / delete-word / clear-all over transcript | `DictationCommand` |
| `ConfidenceGate` | accept/reject ASR when token log-probs exist | `ConfidenceGate` |
| `ClipboardCommands` | copy that / paste that vs session buffer | `DictationCommand` |
| `AdaptivePeek` | peek interval active vs idle | `DecodePolicy.peekSleepNs` |

Bait configs (`*_bait.cfg`) must **fail** — they prove the real invariants are checked.

`specgen` (Go) is not used here: production is Swift. Dual-test pure gates instead.
