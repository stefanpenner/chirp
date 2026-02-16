# Architecture

Chirp is a macOS 26+ menu bar app that performs offline speech-to-text. Hold the fn key, speak, release — transcribed text is typed into the focused app. All inference runs on-device via sherpa-onnx; audio never leaves the machine.

## Component Overview

```
hotkey press/release          microphone
       │                         │
       ▼                         ▼
  HotkeyManager ──→ AppState ←── AudioRecorder
       ▲               │  │
       │     ┌─────────┘  └──────────┐
  HotkeyRecorderPanel  ▼             ▼
                  Transcriber    OverlayPanel
                  (sherpa-onnx)  (waveform HUD)
                        │
                        ▼
                TextPostProcessor
                        │
                        ▼
                  TextInserter ──→ keystrokes into focused app
```

**AppState** orchestrates everything. **ModelManager** handles first-run model download. All speech inference runs through the **CSherpaOnnx** C bridge to sherpa-onnx + onnxruntime dylibs.

## State Machine

```
                      cancel
  ┌──────────────┐──────────→┌─────────────┐
  │ downloading  │           │ needsModel  │
  │  (progress)  │           └──────┬──────┘
  └──────┬───────┘          fn/menu │
         │ model found              ▼
         ▼                  ┌──────────────┐
  ┌───────────────┐  ←──────│ downloading  │ (re-entry)
  │ loadingModel  │         └──────────────┘
  └───────┬───────┘
   success│  failure
    ┌─────┘    └──→ ┌────────┐
    ▼                │ error  │
  ┌───────┐  retry   └────────┘
  │ ready │←────────────┘
  └───┬───┘←──────────────────────────────────┐
 fn press│                                ESC │
       ▼                                      │
  ┌───────────┐  1st audio  ┌───────────┐     │
  │ preparing ├────────────→│ recording │     │
  └─────┬─────┘             └─────┬─────┘     │
     ESC│                 fn rel. │            │
        │                        ▼             │
        │                 ┌──────────────┐     │
        └──→ ready        │ transcribing ├─────┘
                          └──────┬───────┘
                   ←──────┘      │ flush + linger
                  fn press       └──→ ready

  ready ──(fn press, model missing)──→ downloading
```

AppState owns all transitions. User-initiated transitions: `ready → preparing` (fn press), `preparing → recording` (first audio buffer arrives), `recording → transcribing` (fn release), `preparing/recording/transcribing → ready` (ESC cancel), and `transcribing → recording` (fn press rejoin). The rest are automatic.

**Recording sessions**: `preparing → recording` happens automatically when the first audio buffer arrives from the microphone, giving the user visual feedback ("Preparing…") while the audio engine starts. `recording ↔ transcribing` can cycle via fn press/release within the same session — text accumulates across cycles. A session ends naturally (flush + linger timeout) or immediately via ESC cancel. Cancel clears all accumulated text and hides the overlay; already-typed keystrokes are not undone.

Cancelling a download transitions to `needsModel` (clean idle state); from there, pressing fn or selecting a model from the menu re-enters `downloading`. If model files disappear after reaching `ready`, pressing fn re-triggers the download/load flow instead of recording. Pressing fn during `downloading` or `loadingModel` triggers a brief scale-pulse nudge on the overlay (via `downloadNudge`) instead of silently ignoring the press.

## Audio Pipeline

1. **Capture** — `AudioRecorder` wraps AVAudioEngine. Converts hardware sample rate to 16 kHz mono Float32. Before preparing the engine, `requestMicrophoneAccess()` explicitly calls `AVCaptureDevice.requestAccess(for: .audio)` to trigger the macOS permission dialog (required for the app to appear in System Settings → Microphone). If denied, AppState transitions to `.error` with guidance. The engine is created and started once via `prepare()` (called when the model loads) and kept alive between recordings — `startRecording`/`stopRecording` only install/remove the tap for near-instant start. On audio device changes (`AVAudioEngineConfigurationChange`), the engine tears down and re-prepares automatically. The tap closure is `nonisolated static` to avoid `@MainActor` executor checks on the real-time audio thread.

2. **VAD** — `Transcriber.feedAudio()` pushes samples into Silero VAD. When it detects a speech-end boundary, the segment is extracted and transcribed. This gives natural sentence-level chunks.

3. **Transcription** — Offline recognizer (Parakeet TDT 0.6b v2 int8 or CTC variant) runs greedy-search decoding. The `Transcriber` actor serializes all C API access.

4. **Speculative preview** — Every 400ms, `peekTranscription()` runs inference on the last 5 seconds of pending audio. A generation counter (`commitGen`) discards stale previews when a real segment commits.

5. **Post-processing** — `TextPostProcessor.process()` strips fillers ("um", "uh"), deduplicates stutters ("the the" → "the"), normalizes whitespace, and capitalizes "I". Pure function, sub-millisecond.

6. **Insertion** — `TextInserter` posts `CGEvent` keystrokes via `CGEventKeyboardSetUnicodeString`, chunked to 20 UniChars per event. Requires Accessibility permission.

## Model System

`ModelVariant` enumerates available models with download URLs, directory names, and check files:

| Variant | Model | Languages |
|---------|-------|-----------|
| `.tdt` | Parakeet TDT 0.6b v2 int8 | English only |
| `.tdtMultilingual` (default) | Parakeet TDT 0.6b v3 int8 | 25 European languages (auto-detect) |

Both use the same `nemo_transducer` architecture and file layout (`encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`).

`ModelManager` handles:

- **Discovery**: searches App Support, working directory, parent dirs, and bundle resources
- **Download**: URLSession download task with progress (0→0.9 download, 0.9→1.0 extraction)
- **Extraction**: `/usr/bin/tar xjf` to `~/Library/Application Support/Chirp/models/`
- **Cancellation**: `cancel()` invalidates in-flight downloads (used during model switching and user cancel)
- **Deletion**: `deleteModel(variant:)` removes any model from disk (deleting the active model transitions to `needsModel`)

**Model switching** is done via `AppState.switchModel(to:)`, which is only allowed from `.ready`, `.error`, or `.needsModel` state. It cancels any in-flight download, creates a fresh transcriber, persists the selection to UserDefaults, and calls `ensureModel()` to download or load the new model. The menu bar shows all variants with a checkmark on the active one.

**Background downloads**: `AppState.downloadModel(_:)` downloads a non-active variant in the background without switching to it. Progress is tracked per-variant in `backgroundDownloads: [ModelVariant: Double]`. Each background download gets its own `ModelManager` instance stored in `backgroundManagers`.

Silero VAD is bundled in the app; only the ASR model is downloaded at runtime. For SPM development, `scripts/setup.sh` downloads models and dylibs to the repo (gitignored).

## Hotkey

`HotkeyConfig` stores the configured hotkey: `keyCode`, `isModifier` flag, `modifierMask` (for modifier-only keys like fn), `requiredModifiers` (for key combos like ⌘⇧R), and a display `label`. Supports modifier-only keys (fn, Right ⌥), key combos (⌘Space), and plain keys (F5). Persisted in UserDefaults. Full ANSI keycode → label mapping for UI display.

`HotkeyManager` installs a `CGEvent` tap intercepting the configured hotkey events (flagsChanged for modifier keys, keyDown/keyUp for regular keys). It suppresses the key entirely (no system side effects) and calls `onPress`/`onRelease`/`onCancel` closures on the main actor via `Task { @MainActor in }`. ESC (keycode 0x35) is intercepted and suppressed only when `sessionActive` is true (during recording or transcribing); otherwise ESC passes through to the focused app normally. The tap also intercepts NX_SYSDEFINED events (type 14) to suppress the fn emoji picker trigger. A `suppressOnly` flag allows the tap to eat the hotkey without firing callbacks — used while the hotkey recorder dialog is open.

`InlineHotkeyRecorder` provides hotkey recording directly inside the menu bar popover. It installs an `NSEvent` local monitor to capture the next key/modifier press, shows the captured shortcut inline, and offers Save/Cancel/Reset-to-fn buttons. While recording, `suppressOnly` keeps the CGEvent tap active so the current hotkey is suppressed from the system but doesn't trigger recording.

`HotkeyRecorderPanel` is a standalone floating NSPanel alternative with glass vibrancy (NSVisualEffectView, `.popover` material) — kept as a fallback but no longer used by the default menu bar UI.

## Overlay

`OverlayPanel` manages a borderless `NSPanel` hosting a SwiftUI `IslandView`:
- **Download state**: progress bar (blue→cyan gradient, rescaled 0–0.9→0–100%), model name (clickable link), compressed size, and cancel button; pulsing full bar during extraction
- **Loading state**: indeterminate spinner with model name and size
- **needsModel state**: overlay hidden; menu shows "No model loaded" with download button
- **Preparing state**: indeterminate spinner (cyan) with "Preparing…" text while the audio engine starts
- **Recording state**: animated sine-wave waveform driven by audio level
- Committed text (white) + speculative text (gray), in an auto-scrolling ScrollView (maxHeight 120) for long transcriptions
- Conic gradient glow border (active during recording, transcribing, and download)
- Catppuccin-inspired color palette

## Testing

Protocol-based DI (`TranscriberProtocol`, `AudioRecording`, `TextInserting`) enables testing without hardware or ML models. Mock implementations live in `Tests/ChirpTests/Mocks.swift`. Tests use Swift Testing framework.

## Build & Distribution

**SPM** — Single `Chirp` target containing all Swift sources (including `Main.swift`). `CSherpaOnnx` C target wraps the sherpa-onnx header via modulemap. The executable links against `libsherpa-onnx-c-api` and `libonnxruntime` via rpath.

**Bazel** — Two-module split for testability:
- `ChirpLib` (module name `Chirp`): all sources except `Main.swift`, no `@main` entry point
- `ChirpMain`: only `Main.swift` with `@main`, imports `Chirp` and `Sparkle`
- `ChirpTests`: `swift_test` depending on `ChirpLib`
- Prebuilt deps fetched via Bazel repo rules (`deps.bzl`): sherpa-onnx dylibs, Sparkle.framework, Silero VAD
- Types used by `Main.swift` (`AppState`, `Status`, `ModelVariant`, etc.) are `public` to cross the module boundary

`scripts/package.sh` creates a signed `.app` bundle + DMG:
- Copies dylibs to `Frameworks/`, fixes rpaths to `@executable_path/../Frameworks`
- Code-signs with hardened runtime
- Entitlements: microphone access, library validation disabled (for unsigned dylibs)
- `Info.plist` sets `LSUIElement: true` (no dock icon)

**Homebrew** — `HomebrewFormula/chirp.rb` is a cask formula pointing to the GitHub Releases DMG. The release workflow updates the version and SHA256 on each tag push.

## Files

| File | Purpose |
|------|---------|
| `ChirpApp.swift` | AppState state machine (public API for cross-module access) |
| `Main.swift` | `@main` SwiftUI app entry point (window-style menu bar popover, Catppuccin theme) |
| `Protocols.swift` | DI boundaries: TranscriberProtocol, AudioRecording, TextInserting |
| `Transcriber.swift` | Actor wrapping sherpa-onnx offline recognizer + VAD |
| `AudioRecorder.swift` | AVAudioEngine mic capture with sample-rate conversion |
| `TextInserter.swift` | CGEvent keyboard simulation |
| `TextPostProcessor.swift` | Filler removal, dedup, whitespace normalization |
| `HotkeyManager.swift` | HotkeyConfig + configurable key event tap |
| `HotkeyRecorder.swift` | InlineHotkeyRecorder (menu bar) + HotkeyRecorderPanel (standalone) |
| `OverlayPanel.swift` | Floating waveform HUD |
| `ModelManager.swift` | Model download, extraction, discovery |
| `ModelVariant.swift` | Model metadata enum with persistence |
