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
| `CapNext` | one-shot arm: next content capitalizes first word then clears | `AppState.capitalizeNextWord` + `DictationCommand.capNext` |
| `InsertStamp` | formatDate/formatTime always non-empty (clock injectable) | `InsertStamp` |
| `SpellMode` | sticky spell mode (letter packing) | `SpellMode` / `SpellTransform` |
| `NoSpaceMode` | sticky no-space mode (empty segment separators) | `NoSpaceMode` / `AppState.noSpaceMode` |
| `PackAcronyms` | safer auto-pack of single-letter runs (≥3 or allowlisted pairs) | `SpellTransform.packAcronyms` |
| `ReplaceThat` | multi-step replace: arm then next content swaps last | `ReplaceDecision` |
| `ListCounter` | session numbered-list index for next number | `SpokenListITN` |
| `ScratchUndo` | **legacy / no bait** single-level scratch (superseded by `EditStack`) | — |
| `EditCommands` | coarse length model of edit commands (see `EditStack` for stack) | `DictationCommand` |
| `ConfidenceGate` | length-aware accept/reject when token log-probs exist | `ConfidenceGate` |
| `DecodeReject` | energy/silence + log-prob composite reject (Parakeet nil scores) | `DecodeReject` |
| `ClipboardCommands` | copy that / paste that vs session buffer | `DictationCommand` |
| `DuplicateCommand` | duplicate that: clipboard = lastDelta; buffer grows by lastDelta | `DictationCommand.duplicateThat` + `EditStack.lastDelta` |
| `FormatCommands` | format path collapses selection so next type does not replace | `AppState.performFormatThat` + clearSelection |
| `TranscriptSelection` | last-sentence / last-paragraph / last-line lengths ≤ total buffer | `TranscriptSelection` + select last sentence/para + line nav |
| `DeleteSegment` | delete last sentence/para/line: totalLen shrinks by lastSegLen | last-segment delete length dual (`TranscriptSelection` + edit path) |
| `PageScroll` | page up/down leaves session bufferLen unchanged | `DictationCommand.pageUp/pageDown` + `performScrollPage` |
| `KeyCommand` | press backspace/escape/undo/redo/forward-delete leave session bufferLen unchanged | `DictationCommand.pressBackspace/pressEscape/pressUndo/pressRedo/pressForwardDelete` + performPress* |
| `WordSelect` | select next/prev word leaves session bufferLen unchanged | `DictationCommand.selectNextWord/selectPreviousWord` + `performSelectWord` |
| `SentenceSelect` | select first/last/next sentence leaves session bufferLen unchanged | `DictationCommand.selectLastSentence` + `performSelectLastSentence` (+ first/next sentence select contract) |
| `MoveSentence` | previous/next sentence move leaves session bufferLen unchanged | `DictationCommand.moveToPreviousSentence/moveToNextSentence` + `performMoveTo*Sentence` |
| `SentenceCursor` | progressive sentence nav index (`-1`/nil = end; next/prev walk) | `AppState.sentenceNavIndex` (nil = end); dual of progressive 3rd+ next |
| `ParagraphCursor` | progressive paragraph nav index (`-1`/nil = end; next/prev/delete) | `AppState.paragraphNavIndex` (nil = end); dual of select/move/delete next paragraph |
| `LineCursor` | progressive line nav index (`-1`/nil = end; next/prev/delete) | `AppState.lineNavIndex` (nil = end); dual of select next/previous/delete next line |
| `MultiUnitEdit` | delete last N trailing units clamps and stays non-negative | `DictationCommand.deleteLast*`(count) + `performDeleteLastUnits` |
| `CharacterEdit` | delete previous N characters clamps to bufferLen | `DictationCommand.deletePreviousCharacters` + `performDeletePreviousCharacters` |
| `MoveN` | move N words/characters leaves session bufferLen unchanged | `DictationCommand.movePrevious/NextWords` + `movePrevious/NextCharacters` + `performMoveWords` / `performMoveCharacters` |
| `SelectLastWords` | select last N trailing words leaves session bufferLen unchanged | `DictationCommand.selectLastWords` + `TranscriptSelection.lastWords` + `performSelectLastWords` |
| `SelectionCommit` | select any in-range window → re-dictate splices; typedToApp == textLen | `SelectionCommitDecision.bufferAfterRangeReplace` + `AppState.sessionSelection` |
| `ReplacePhrase` | replace X with Y last match; miss is no-op; typedToApp == textLen | `PhraseReplaceDecision` + `AppState.performReplacePhrase` |
| `VadEndpoint` | user VAD silence/threshold always clamp into safe range | `VadSettings.clamp` + min silence / threshold ranges |
| `AdaptivePeek` | peek interval active vs idle | `DecodePolicy.peekSleepNs` |
| `PeekCache` | skip peek ASR when pending count unchanged | `DecodePolicy.shouldReusePeek` |
| `PeekCommitHyp` | reuse peek hyp on commit when speech-window sig matches | `DecodePolicy.shouldReuseCommitHyp` + `Transcriber` feed/flush |

Bait configs (`*_bait.cfg`) must **fail** — they prove the real invariants are checked.

Config path is relative to the **spec directory** (TLC’s cwd), not the repo root:

```bash
# real Inv must pass
tlc specs/AdaptivePeek.tla
tlc specs/PeekCache.tla
tlc specs/CancelVoid.tla
tlc specs/CapsMode.tla
tlc specs/CapNext.tla
tlc specs/InsertStamp.tla
tlc specs/ClipboardCommands.tla
tlc specs/DuplicateCommand.tla
tlc specs/SpellMode.tla
tlc specs/NoSpaceMode.tla
tlc specs/PackAcronyms.tla
tlc specs/ConfidenceGate.tla
tlc specs/DecodeReject.tla
tlc specs/EditCommands.tla
tlc specs/EditStack.tla
tlc specs/FormatCommands.tla
tlc specs/TranscriptSelection.tla
tlc specs/DeleteSegment.tla
tlc specs/PageScroll.tla
tlc specs/KeyCommand.tla
tlc specs/WordSelect.tla
tlc specs/SentenceSelect.tla
tlc specs/MoveSentence.tla
tlc specs/SentenceCursor.tla
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
tlc -c CapNext_bait.cfg specs/CapNext.tla
tlc -c InsertStamp_bait.cfg specs/InsertStamp.tla
tlc -c ClipboardCommands_bait.cfg specs/ClipboardCommands.tla
tlc -c DuplicateCommand_bait.cfg specs/DuplicateCommand.tla
tlc -c SpellMode_bait.cfg specs/SpellMode.tla
tlc -c NoSpaceMode_bait.cfg specs/NoSpaceMode.tla
tlc -c PackAcronyms_bait.cfg specs/PackAcronyms.tla
tlc -c ConfidenceGate_bait.cfg specs/ConfidenceGate.tla
tlc -c DecodeReject_bait.cfg specs/DecodeReject.tla
tlc -c EditCommands_bait.cfg specs/EditCommands.tla
tlc -c EditStack_bait.cfg specs/EditStack.tla
tlc -c FormatCommands_bait.cfg specs/FormatCommands.tla
tlc -c TranscriptSelection_bait.cfg specs/TranscriptSelection.tla
tlc -c DeleteSegment_bait.cfg specs/DeleteSegment.tla
tlc -c PageScroll_bait.cfg specs/PageScroll.tla
tlc -c KeyCommand_bait.cfg specs/KeyCommand.tla
tlc -c WordSelect_bait.cfg specs/WordSelect.tla
tlc -c SentenceSelect_bait.cfg specs/SentenceSelect.tla
tlc -c MoveSentence_bait.cfg specs/MoveSentence.tla
tlc -c SentenceCursor_bait.cfg specs/SentenceCursor.tla
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
| `CapNext_bait` | after cap-commit may remain armed | `CommitArmedClears` |
| `InsertStamp_bait` | format may leave lastLen = 0 | `FormatNonEmpty` |
| `ClipboardCommands_bait` | copy may leave clip ≠ transcript | `CopyMirrors` |
| `DuplicateCommand_bait` | after duplicate, clip may ≠ lastDelta | `DuplicateHoldsDelta` |
| `SpellMode_bait` | reset may leave spell on | `ResetYieldsOff` |
| `NoSpaceMode_bait` | reset may leave no-space on | `ResetYieldsOff` |
| `PackAcronyms_bait` | packs may diverge from ≥3 / allowlisted-pair rule | `PacksIffRule` |
| `ConfidenceGate_bait` | no-scores may reject | `NoScoresAccept` |
| `DecodeReject_bait` | silence may accept non-empty hyp | `SilenceNonEmptyRejects` |
| `EditCommands_bait` | lastTyped may exceed textLen | `LastTypedWithinText` |
| `EditStack_bait` | typed length may diverge from text | `TypedMatchesText` |
| `FormatCommands_bait` | format may leave selection active | `FormatImpliesCollapsed` |
| `TranscriptSelection_bait` | last segment may exceed total | `LastWithinTotal` |
| `DeleteSegment_bait` | after delete total may ≠ old − lastSeg | `DeleteSubtracts` |
| `PageScroll_bait` | scroll may change bufferLen | `ScrollPreservesBuffer` |
| `KeyCommand_bait` | key command may change bufferLen | `KeyPreservesBuffer` |
| `WordSelect_bait` | select-word may change bufferLen | `SelectPreservesBuffer` |
| `SentenceSelect_bait` | select-sentence may change bufferLen | `SelectPreservesBuffer` |
| `MoveSentence_bait` | move-sentence may change bufferLen | `MovePreservesBuffer` |
| `SentenceCursor_bait` | index may leave legal range | `IndexInRange` |
| `ListCounter_bait` | end/reset may leave n ≠ 1 | `EndOrResetYieldsOne` |
| `PeekCommit_bait` | speculative text may appear while idle | `SpecOnlyWhileRecording` |
| `PipelineRebuild_bait` | type bounds may fail | `TypeOK` |
| `ReplaceThat_bait` | may await with no last phrase | `AwaitNeedsLastTyped` |
| `SegmentJoin_bait` | sentence sep may appear with no text | `SentenceImpliesContext` |
| `SessionMachine_bait` | ready may not be idle | `ReadyIsIdle` |
| `TranscriberBuffer_bait` | commits never use pending | `lastCommitSrc = "none"` |

`specgen` (Go) is not used here: production is Swift. Dual-test pure gates instead.
