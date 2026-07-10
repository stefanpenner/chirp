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

Bait configs (`*_bait.cfg`) must **fail** — they prove the real invariants are checked.

`specgen` (Go) is not used here: production is Swift. Dual-test pure gates instead.
