# Architecture

Chirp is a macOS 26+ menu bar app that performs offline speech-to-text. Hold the fn key, speak, release — transcribed text is typed into the focused app. All inference runs on-device via sherpa-onnx by default; audio never leaves the machine unless the user opts into cloud AI features.

## Component Overview

```
hotkey press/release          microphone
       │                         │
       ▼                         ▼
  HotkeyManager ──→ AppState ←── AudioRecorder
       ▲               │  │  ▲
       │     ┌─────────┘  │  └── InputDeviceManager
       │     │            └──────────┐
  HotkeyRecorderPanel  ▼             ▼
                  Pipeline         OverlayPanel
               ┌────┴────┐        (waveform HUD)
           Offline    Cloud
           Pipeline   Pipeline
               │          │
          Transcriber  STTClient ──→ cloud API
          (sherpa-onnx)    │
               │           │
               ▼           ▼
          PostProcessing
        ┌───┬────┴────┬───────┐
      Regex  LLM   Chained
              │
          LLMClient ──→ cloud API
              │
              ▼
        TextInserter ──→ keystrokes into focused app
```

**AppState** orchestrates everything. **ModelManager** handles first-run model download. All speech inference runs through the **CSherpaOnnx** C bridge to sherpa-onnx + onnxruntime dylibs. Optional cloud features use **STTClient** and **LLMClient** protocols with provider implementations for OpenAI, Anthropic, and Google.

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
  ┌───────────┐  fn release  ┌──────────────┐ │
  │ recording ├─────────────→│ transcribing ├─┘
  └─────┬─────┘  ←───────────┴──────┬───────┘
     ESC│         fn press          │ flush + linger
        └──→ ready                  └──→ ready

  ready ──(fn press, model missing)──→ downloading
```

AppState owns all transitions. User-initiated transitions: `ready → recording` (fn press), `recording → transcribing` (fn release), `recording/transcribing → ready` (ESC cancel), and `transcribing → recording` (fn press rejoin). The rest are automatic.

**Recording sessions**: `recording ↔ transcribing` can cycle via fn press/release within the same session — text accumulates across cycles. A session ends naturally (flush + linger timeout) or immediately via ESC cancel. Cancel clears all accumulated text and hides the overlay; already-typed keystrokes are not undone.

Cancelling a download transitions to `needsModel` (clean idle state); from there, pressing fn re-enters `downloading`. If model files disappear after reaching `ready`, pressing fn re-triggers the download/load flow instead of recording. Pressing fn during `downloading` or `loadingModel` triggers a brief scale-pulse nudge on the overlay (via `downloadNudge`) instead of silently ignoring the press.

## Transcription Pipeline

AppState delegates to a `TranscriptionPipeline` protocol instead of calling the transcriber and post-processor directly. Two implementations exist:

**OfflineTranscriptionPipeline** wraps the existing `Transcriber` + post-processor. In regex-only mode, it streams segments incrementally (existing behavior: text typed as you speak, speculative preview every 400ms). In LLM mode, it accumulates regex-cleaned segments internally, then runs the LLM on the full text during flush — no text is typed until the user releases the hotkey.

**CloudTranscriptionPipeline** accumulates raw audio during recording (overlay shows "Listening..."), then sends it to a cloud STT service on flush. Post-processing (regex, LLM, or chained) runs after cloud STT returns. The overlay shows "Processing..." during the cloud call. No speculative preview in cloud mode.

Two boolean flags on AppState control UX behavior:
- `pipelineTypesIncrementally` — true only for offline+regex (text typed during recording)
- `pipelineSupportsPreview` — true only for offline+regex (speculative peek enabled)

These are set by `rebuildPipeline()` when AI settings change.

### Post-Processing

`TextPostProcessing` protocol with three implementations:
- **RegexPostProcessor** — wraps existing `TextPostProcessor` (sub-ms, synchronous)
- **LLMPostProcessor** — sends text to an LLM for grammar/punctuation cleanup
- **ChainedPostProcessor** — regex first, then LLM refinement

On LLM error, the pipeline silently falls back to regex-only output.

### Cloud Providers

```
STTClient (protocol)     — transcribe(samples:sampleRate:) → String
LLMClient (protocol)     — complete(system:user:) → String

Implementations:
├── OpenAIProvider    — STT (Whisper) + LLM (GPT) via OpenAI-compatible API
├── AnthropicProvider — LLM only (Messages API)
└── GoogleProvider    — STT (Cloud Speech) + LLM (Gemini)
```

The `baseURL` on each endpoint enables gateways: a company proxy at `https://ai.internal.corp/v1` speaking OpenAI protocol works out of the box. OpenRouter and other OpenAI-compatible services work the same way.

### API Configuration

```
AISettings (persisted in UserDefaults as Codable blob)
├── transcriptionMode: .offline | .cloud
├── postProcessingMode: .regex | .llm | .regexThenLLM
├── sttEndpointID / llmEndpointID (UUID references)
├── sttModel / llmModel / llmSystemPrompt (task-level config)
└── endpoints: [APIEndpoint]
        ├── apiProtocol: .openAI | .anthropic | .google
        ├── baseURL (supports custom gateways)
        └── apiKeyRef (Keychain account name, NOT raw key)
```

Model selection (STT model, LLM model, system prompt) lives on `AISettings` rather than on individual endpoints, since models are chosen per-task, not per-provider. Endpoints define only connectivity (protocol, URL, API key).

API keys are stored in the macOS **Keychain** via `KeychainHelper`, never in UserDefaults.

## Audio Pipeline

1. **Capture** — `AudioRecorder` wraps AVAudioEngine. Converts hardware sample rate to 16 kHz mono Float32. Before preparing the engine, `requestMicrophoneAccess()` explicitly calls `AVCaptureDevice.requestAccess(for: .audio)` to trigger the macOS permission dialog (required for the app to appear in System Settings → Microphone). If denied, AppState transitions to `.error` with guidance. The engine is created and started once via `prepare()` (called when the model loads) and kept alive between recordings — `startRecording`/`stopRecording` only install/remove the tap for near-instant start. On stop, the recorder's tap is removed before the AsyncStream continuation is finished, so in-flight I/O thread callbacks can still yield their buffer. On audio device changes (`AVAudioEngineConfigurationChange`), the engine tears down and re-prepares automatically. The tap closure is `nonisolated static` to avoid `@MainActor` executor checks on the real-time audio thread. **Device selection**: `InputDeviceManager` enumerates CoreAudio input devices and persists the user's choice by UID (stable across reboots). When `selectInputDevice(_:)` is called, the engine tears down and re-prepares with the new device set via `kAudioOutputUnitProperty_CurrentDevice` on the input AudioUnit before `inputNode` is accessed.

2. **VAD** — `Transcriber.feedAudio()` pushes samples into Silero VAD and appends them to `pendingAudio`. When the VAD detects a speech-end boundary (≥0.5s silence), the segment is extracted, transcribed, and `pendingAudio` is cleared. This gives natural sentence-level chunks.

3. **Transcription** — Offline recognizer (Parakeet TDT 0.6b v3 int8, multilingual) runs greedy-search decoding. The `Transcriber` actor serializes all C API access.

4. **Speculative preview** — Every 400ms, `peekTranscription()` runs inference on `pendingAudio` (last 5 seconds, gated on VAD speech detection). A generation counter (`commitGen`) discards stale previews when a real segment commits. Disabled when `pipelineSupportsPreview` is false (cloud or LLM modes).

5. **Flush** — When recording stops, `flush()` transcribes remaining `pendingAudio` directly (same source as peek) rather than VAD segment audio. This avoids onset-lag clipping where the VAD's speech-onset detection lags behind the actual start of speech. Guarded by requiring both VAD flush segments and sufficient `pendingAudio` to prevent hallucinated words from post-commit noise.

6. **Post-processing** — `TextPostProcessor.process()` strips fillers ("um", "uh"), deduplicates stutters ("the the" → "the"), normalizes whitespace, and capitalizes "I". Pure function, sub-millisecond. When LLM post-processing is enabled, this runs first (within the pipeline), then the LLM refines the full text on flush.

7. **Insertion** — `TextInserter` posts `CGEvent` keystrokes via `CGEventKeyboardSetUnicodeString`, chunked to 20 UniChars per event. Requires Accessibility permission. In non-incremental mode (cloud/LLM), text is typed once after flush completes.

## Model System

`ModelVariant` holds static configuration for the single model: Parakeet TDT 0.6b v3 int8 (25 European languages, auto-detect). Uses `nemo_transducer` architecture with `encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`.

`ModelManager` handles:

- **Discovery**: searches App Support, bundle resources, and `CHIRP_MODEL_DIR` env var
- **Download**: URLSession download task with progress (0→0.9 download, 0.9→1.0 extraction)
- **Extraction**: `/usr/bin/tar xjf` to `~/Library/Application Support/Chirp/models/`
- **Cancellation**: `cancel()` invalidates in-flight downloads

Silero VAD is bundled in the app; only the ASR model is downloaded at runtime. For SPM development, `scripts/setup.sh` downloads models and dylibs to the repo (gitignored).

## Hotkey

`HotkeyConfig` stores the configured hotkey: `keyCode`, `isModifier` flag, `modifierMask` (for modifier-only keys like fn), `requiredModifiers` (for key combos like ⌘⇧R), and a display `label`. Supports modifier-only keys (fn, Right ⌥), key combos (⌘Space), and plain keys (F5). Persisted in UserDefaults. Full ANSI keycode → label mapping for UI display.

`HotkeyManager` installs a `CGEvent` tap intercepting the configured hotkey events (flagsChanged for modifier keys, keyDown/keyUp for regular keys). It suppresses the key entirely (no system side effects) and calls `onPress`/`onRelease`/`onCancel` closures on the main actor via `Task { @MainActor in }`. ESC (keycode 0x35) is intercepted and suppressed only when `sessionActive` is true (during recording or transcribing); otherwise ESC passes through to the focused app normally. The tap also intercepts NX_SYSDEFINED events (type 14) to suppress the fn emoji picker trigger. A `suppressOnly` flag allows the tap to eat the hotkey without firing callbacks — used while the hotkey recorder dialog is open. If `CGEvent.tapCreate` fails (Accessibility not yet granted), a background poller checks `AXIsProcessTrusted()` every second and retries `setupEventTap()` automatically once the permission is granted — no app restart required.

`InlineHotkeyRecorder` provides hotkey recording directly inside the menu bar popover. It installs an `NSEvent` local monitor to capture the next key/modifier press and immediately saves the new hotkey via `appState.updateHotkey()` — no intermediate confirmation step. ESC cancels recording without changing the hotkey. While recording, `suppressOnly` keeps the CGEvent tap active so the current hotkey is suppressed from the system but doesn't trigger recording.

`HotkeyRecorderPanel` is a standalone floating NSPanel alternative with glass vibrancy (NSVisualEffectView, `.popover` material) — kept as a fallback but no longer used by the default menu bar UI.

## Overlay

`OverlayPanel` manages a borderless `NSPanel` hosting a SwiftUI `IslandView`:
- **Download state**: progress bar (blue→cyan gradient, rescaled 0–0.9→0–100%), model name (clickable link), compressed size, and cancel button; pulsing full bar during extraction
- **Loading state**: indeterminate spinner with model name and size
- **needsModel state**: overlay hidden; menu shows "No model loaded" with download button
- **Recording state**: animated sine-wave waveform driven by audio level
- Committed text (white) + speculative text (gray), in an auto-scrolling ScrollView (maxHeight 120) for long transcriptions
- **Transcribing state**: shows "Finalizing..." (offline+regex) or "Processing..." (cloud/LLM)
- Conic gradient glow border (active during recording, transcribing, and download)
- Catppuccin-inspired color palette

## Settings

`SettingsView` provides a tabbed settings window (opened via "Settings..." in the menu bar):
- **AI tab**: transcription mode picker (offline/cloud) with inline STT model field, post-processing mode picker (regex/LLM/regex+LLM) with inline LLM model + system prompt fields, endpoint selector pickers, endpoint list with add/edit/delete
- **Endpoint editor**: connectivity only — protocol picker, base URL, API key (stored in Keychain), enable/disable toggle

`SettingsWindowController` manages the `NSWindow` lifecycle (single instance, bring-to-front on re-open).

The menu bar shows an "AI Mode" label (e.g. "Cloud STT + LLM") when non-default modes are active.

## Testing

Protocol-based DI (`TranscriberProtocol`, `AudioRecording`, `TextInserting`) enables testing without hardware or ML models. Mock implementations live in `Tests/ChirpTests/Mocks.swift`. Tests use Swift Testing framework.

The pipeline abstraction is transparent to existing tests: the default `OfflineTranscriptionPipeline` wraps the injected `MockTranscriber` with `RegexPostProcessor`, preserving identical behavior.

## Build & Distribution

**SPM** — Single `Chirp` target containing all Swift sources (including `Main.swift`). `CSherpaOnnx` C target wraps the sherpa-onnx header via modulemap. The executable links against `libsherpa-onnx-c-api` and `libonnxruntime` via rpath.

**Bazel** — Two-module split for testability:
- `ChirpLib` (module name `Chirp`): all sources except `Main.swift` (including `Providers/*.swift`), no `@main` entry point
- `ChirpMain`: only `Main.swift` with `@main`, imports `Chirp` and `Sparkle`
- `ChirpTests`: `swift_test` depending on `ChirpLib`
- Prebuilt deps fetched via Bazel repo rules (`deps.bzl`): sherpa-onnx dylibs, Sparkle.framework, Silero VAD
- Types used by `Main.swift` (`AppState`, `Status`, `AISettings`, `TranscriptionMode`, `PostProcessingMode`, etc.) are `public` to cross the module boundary

`scripts/package.sh` creates a signed `.app` bundle + DMG:
- Copies dylibs to `Frameworks/`, fixes rpaths to `@executable_path/../Frameworks`
- Code-signs with hardened runtime
- Entitlements: microphone access, library validation disabled (for unsigned dylibs), network client (for cloud API access)
- `Info.plist` sets `LSUIElement: true` (no dock icon)

**Homebrew** — `HomebrewFormula/chirp.rb` is a cask formula pointing to the GitHub Releases DMG. The release workflow updates the version and SHA256 on each tag push.

## Files

| File | Purpose |
|------|---------|
| `ChirpApp.swift` | AppState state machine, pipeline management (public API for cross-module access) |
| `Main.swift` | `@main` SwiftUI app entry point (window-style menu bar popover, AI mode label, Catppuccin theme) |
| `Protocols.swift` | DI boundaries: TranscriberProtocol, AudioRecording, TextInserting |
| `TranscriptionPipeline.swift` | Pipeline protocol + Offline/Cloud implementations |
| `TextPostProcessing.swift` | Post-processing protocol + Regex/LLM/Chained implementations |
| `CloudSTT.swift` | STTClient protocol + WAV encoder |
| `CloudLLM.swift` | LLMClient protocol |
| `Providers/OpenAIProvider.swift` | OpenAI-compatible STT (Whisper) + LLM (GPT) |
| `Providers/AnthropicProvider.swift` | Anthropic Messages API (LLM only) |
| `Providers/GoogleProvider.swift` | Google Cloud Speech + Gemini |
| `APIConfiguration.swift` | Data models: APIEndpoint, AISettings, Codable persistence |
| `KeychainHelper.swift` | Keychain CRUD for API keys |
| `SettingsView.swift` | Settings window UI (AI tab, endpoint editor) |
| `SettingsWindow.swift` | NSWindow management for Settings |
| `Transcriber.swift` | Actor wrapping sherpa-onnx offline recognizer + VAD |
| `AudioRecorder.swift` | AVAudioEngine mic capture with sample-rate conversion |
| `InputDeviceManager.swift` | CoreAudio input device enumeration, UID-based persistence, hardware-change listener |
| `TextInserter.swift` | CGEvent keyboard simulation |
| `TextPostProcessor.swift` | Filler removal, dedup, whitespace normalization |
| `HotkeyManager.swift` | HotkeyConfig + configurable key event tap |
| `HotkeyRecorder.swift` | InlineHotkeyRecorder (menu bar) + HotkeyRecorderPanel (standalone) |
| `OverlayPanel.swift` | Floating waveform HUD (cloud-aware status text) |
| `ModelManager.swift` | Model download, extraction, discovery |
| `ModelVariant.swift` | Model configuration constants |
| `AudioDucker.swift` | System volume duck/unduck during recording |
