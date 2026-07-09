# Architecture

Chirp is a macOS 15+ menu bar app that performs offline speech-to-text. Hold the fn key, speak, release — transcribed text is typed into the focused app. All inference runs on-device via sherpa-onnx by default; audio never leaves the machine unless the user opts into cloud AI features.

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
          SpeakerVerifier (optional gate)
               │
               ▼
          PostProcessing
        ┌───┬────┴────┬───────┬──────────┐
      Regex  LLM   Chained  OfflineLLM  ChainedOffline
              │                  │
          LLMClient ──→       T5PostProcessor
           cloud API       (ONNXSession + T5Tokenizer)
              │
              ▼
        TextInserter ──→ keystrokes into focused app
```

**AppState** orchestrates everything. **ModelManager** handles first-run ASR model download. All speech inference runs through the **CSherpaOnnx** C bridge to sherpa-onnx + onnxruntime dylibs. Optional cloud features use **STTClient** and **LLMClient** protocols with provider implementations for OpenAI, Anthropic, and Google. Offline post-processing uses **T5PostProcessor** which runs T5-small inference via the **COnnxRuntime** C bridge (same onnxruntime dylib, separate Swift module exposing the raw ORT C API). Optional **SpeakerVerifier** gates segments by comparing speaker embeddings against an enrolled reference via ECAPA-TDNN (~20 MB ONNX model).

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

**CloudTranscriptionPipeline** accumulates raw audio during recording, then sends it to a cloud STT service on flush. Post-processing (regex, LLM, or chained) runs after cloud STT returns. The overlay shows "Processing..." during the cloud call. The pipeline also feeds the local transcriber in parallel for speculative preview — users see live local preview while recording, but the final typed text comes from the higher-quality cloud STT.

Both pipeline implementations accept an optional `speakerVerifier` (conforming to `SpeakerVerifying`) and `speakerThreshold`. When a speaker is enrolled and verification is enabled, the pipeline gates each segment: in `OfflineTranscriptionPipeline`, accumulated audio is verified after transcription and rejected if the cosine similarity falls below the threshold; in `CloudTranscriptionPipeline`, the full accumulated audio is verified before sending to the cloud. On verification error, segments pass through (graceful degradation).

Two boolean flags on AppState control UX behavior:
- `pipelineTypesIncrementally` — true only for offline+regex (text typed during recording)
- `pipelineSupportsPreview` — true for offline modes and cloud mode (local transcriber provides peek in both cases)

These are set by `rebuildPipeline()` when AI settings change. If settings change during an active recording/transcribing session, the rebuild is deferred (`pipelineNeedsRebuild` flag) and applied automatically when the session ends (natural flush or ESC cancel).

### Post-Processing

`TextPostProcessing` protocol with six implementations:
- **PassthroughPostProcessor** — no-op, returns text unchanged (for `.none` mode)
- **RegexPostProcessor** — wraps existing `TextPostProcessor` (sub-ms, synchronous)
- **LLMPostProcessor** — sends text to a cloud LLM for grammar/punctuation cleanup
- **ChainedPostProcessor** — regex first, then cloud LLM refinement
- **OfflineLLMPostProcessor** — runs T5-small locally via ONNX Runtime (no internet needed)
- **ChainedOfflinePostProcessor** — regex first, then offline T5 refinement

On LLM error (cloud or offline), the pipeline logs the failure via `Log.cloud` and falls back to regex-only output. Cloud API calls (STT and LLM post-processing) are wrapped with `RetryHelper.withRetry` — up to 3 attempts with exponential backoff (1s, 2s, 4s + jitter) for transient failures (URLError, HTTP 429, HTTP 5xx). Non-transient errors (noAPIKey, invalidResponse) fail immediately.

### Cloud Providers

```
STTClient (protocol)     — transcribe(samples:sampleRate:) → String
LLMClient (protocol)     — complete(system:user:) → String

Implementations:
├── OpenAIProvider    — STT (Whisper) + LLM (GPT) via OpenAI-compatible API
├── AnthropicProvider — LLM only (Messages API)
└── GoogleProvider    — STT (Cloud Speech) + LLM (Gemini)
```

All providers share HTTP request/response boilerplate via `HTTPHelper` (status code validation, JSON parsing). Each provider accepts an injectable `URLSession` (default `.shared`) for testability. The `baseURL` on each endpoint enables gateways: a company proxy at `https://ai.internal.corp/v1` speaking OpenAI protocol works out of the box. OpenRouter and other OpenAI-compatible services work the same way.

### API Configuration

```
AISettings (persisted in UserDefaults as Codable blob)
├── endpoints: [APIEndpoint]          — shared provider pool
│       ├── apiProtocol: .openAI | .anthropic | .google
│       ├── baseURL (supports custom gateways)
│       └── apiKeyRef (Keychain account name, NOT raw key)
├── modes: [AIMode]                   — named pipeline presets
│       ├── name: String
│       ├── transcriptionMode: .offline | .cloud
│       ├── postProcessingMode: .none | .regex | .llm | .regexThenLLM | .offlineLLM | .regexThenOfflineLLM
│       ├── sttEndpointID / llmEndpointID (UUID references into endpoints)
│       └── sttModel / llmModel / llmSystemPrompt (per-mode config)
└── activeModeID: UUID?               — currently selected mode
```

Each **AIMode** is a self-contained pipeline preset with its own provider and model selections. Two defaults ship: "Offline" (local STT + regex) and "Offline + Fixup" (local STT + regex + offline T5 LLM). Users can create custom modes (e.g. "Cloud Dictation" with cloud STT + cloud LLM targeting specific providers). Endpoints define connectivity (protocol, URL, API key); modes reference endpoints by UUID. The custom decoder handles backward compatibility — old flat settings are replaced with defaults while preserving endpoints.

API keys are stored in the macOS **Keychain** via `KeychainHelper`, never in UserDefaults.

## Audio Pipeline

1. **Capture** — `AudioRecorder` wraps AVAudioEngine. Converts hardware sample rate to 16 kHz mono Float32. Before preparing the engine, `requestMicrophoneAccess()` explicitly calls `AVCaptureDevice.requestAccess(for: .audio)` to trigger the macOS permission dialog (required for the app to appear in System Settings → Microphone). If denied, AppState transitions to `.error` with guidance. The engine is created and started once via `prepare()` (called when the model loads) and kept alive between recordings — `startRecording`/`stopRecording` only install/remove the tap for near-instant start. On stop, the recorder's tap is removed before the AsyncStream continuation is finished, so in-flight I/O thread callbacks can still yield their buffer. On audio device changes (`AVAudioEngineConfigurationChange`), the engine tears down and re-prepares automatically. The tap closure is `nonisolated static` to avoid `@MainActor` executor checks on the real-time audio thread. **Device selection**: `InputDeviceManager` enumerates CoreAudio input devices and persists the user's choice by UID (stable across reboots). When `selectInputDevice(_:)` is called, the engine tears down and re-prepares with the new device set via `kAudioOutputUnitProperty_CurrentDevice` on the input AudioUnit before `inputNode` is accessed. **Noise reduction**: When `voiceProcessingEnabled` is true (default), `prepare()` calls `inputNode.setVoiceProcessingEnabled(true)` to switch to `kAudioUnitSubType_VoiceProcessingIO`, providing built-in noise suppression, AEC, and AGC. Toggling requires re-preparing the engine. The noise reduction setting is persisted in UserDefaults (`chirp.noiseReduction`) and toggled from the Audio settings tab.

2. **VAD** — `Transcriber.feedAudio()` pushes samples into Silero VAD and appends them to `pendingAudio`. When the VAD detects a speech-end boundary (≥0.5s silence), the VAD segment is discarded as audio — VAD only endpoints. Decode uses `pendingAudio` (full raw buffer since last commit), then clears it. This avoids Silero onset-lag clipping leading words. Formal model: `specs/TranscriberBuffer.tla`.

3. **Transcription** — Offline recognizer (Parakeet TDT 0.6b v3 int8, multilingual) runs greedy-search decoding. The `Transcriber` actor serializes all C API access.

4. **Speculative preview** — Every 400ms, `peekTranscription()` runs inference on `pendingAudio` (last 5 seconds, gated on VAD speech detection). A generation counter (`commitGen`) discards stale previews when a real segment commits. Disabled when `pipelineSupportsPreview` is false (cloud or LLM modes).

5. **Flush** — When recording stops, `flush()` transcribes remaining `pendingAudio` (same source as peek and mid-recording commit). Guarded by requiring both VAD flush segments and sufficient `pendingAudio` to prevent hallucinated words from post-commit noise.

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

`T5ModelManager` handles the optional T5-small model download (encoder_model.onnx, decoder_model.onnx, tokenizer.json — ~375 MB total from HuggingFace `optimum/t5-small`). Stored in `~/Library/Application Support/Chirp/models/t5-small-onnx/`. Downloads are triggered from the Settings UI, not on first launch. The model is only needed when offline LLM post-processing modes are selected.

`SpeakerModelManager` handles the optional ECAPA-TDNN speaker embedding model download (`embedding_model.onnx` — ~20 MB from HuggingFace `speechbrain/spkrec-ecapa-voxceleb`). Stored in `~/Library/Application Support/Chirp/models/ecapa-tdnn/`. Download is triggered from the Speaker Verification section of the Audio settings tab. The model is only needed when speaker verification is enabled.

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
- Committed text (white, left-aligned) + speculative text (gray), in a dynamically growing ScrollView (measured via preference key, animated height, max 300pt) that keeps the text area visible mid-session
- **Transcribing state**: shows "Finalizing..." (offline+regex) or "Processing..." (cloud/LLM)
- Conic gradient glow border (active during recording, transcribing, and download)
- Catppuccin-inspired color palette

## Settings

`SettingsView` provides a tabbed settings window (opened via "Settings..." in the menu bar):
- **Audio tab**: toggle for noise reduction (Apple Voice Processing IO), defaults to on, persisted in UserDefaults (`chirp.noiseReduction`). Toggling while idle tears down and re-prepares the audio engine. Speaker Verification section: enable toggle, model download status (`SpeakerModelStatusView`), enrollment flow (`SpeakerEnrollmentView` — 5 pangram phrases recorded via existing AudioRecorder), sensitivity slider (threshold 0.1–0.6). Enrollment data persisted as `SpeakerEnrollment` in UserDefaults (`chirp.speakerEnrollment`)
- **AI tab**: Providers section (endpoint list with add/edit/delete, endpoint editor sheet: protocol picker, base URL, API key stored in Keychain, enable/disable toggle) and AI Modes section (list of named modes with radio selection, edit/delete, AI Mode editor sheet: name, transcription source, regex toggle, LLM toggle with cloud/offline engine, provider + model combo box, system prompt). Model combo boxes use `NSComboBox` (via `ComboBoxField` NSViewRepresentable) with protocol-aware suggestions

`SettingsWindowController` manages the `NSWindow` lifecycle (single instance, bring-to-front on re-open).

The menu bar shows an expandable "AI Mode" picker (same pattern as the microphone picker) listing all user-defined modes. Selecting a mode sets `activeModeID`, saves, and rebuilds the pipeline.

## Testing

Protocol-based DI (`TranscriberProtocol`, `AudioRecording`, `TextInserting`, `SpeakerVerifying`) enables testing without hardware or ML models. Mock implementations live in `Tests/ChirpTests/Mocks.swift` (`MockTranscriber`, `MockAudioRecorder`, `MockTextInserter`, `MockSpeakerVerifier`). Tests use Swift Testing framework.

The pipeline abstraction is transparent to existing tests: the default `OfflineTranscriptionPipeline` wraps the injected `MockTranscriber` with `RegexPostProcessor`, preserving identical behavior. Cloud provider clients are tested via `MockURLProtocol` (custom `URLProtocol` subclass) injected through the `session` parameter, covering happy paths, error handling, and header verification across all five client types.

## Build & Distribution

**SPM** — Single `Chirp` target containing all Swift sources (including `Main.swift`). `CSherpaOnnx` C target wraps the sherpa-onnx header via modulemap. `COnnxRuntime` C target wraps the vendored ONNX Runtime C API header (v1.23.2) via modulemap. The executable links against `libsherpa-onnx-c-api` and `libonnxruntime` via rpath.

**Bazel** — Two-module split for testability:
- `COnnxRuntime`: local `cc_library` with vendored ORT headers, linked against `@sherpa_onnx//:onnxruntime`
- `ChirpLib` (module name `Chirp`): all sources except `Main.swift` (including `Providers/*.swift`), no `@main` entry point; depends on both `@sherpa_onnx//:CSherpaOnnx` and `:COnnxRuntime`
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
| `Protocols.swift` | DI boundaries: TranscriberProtocol, AudioRecording, TextInserting, SpeakerVerifying |
| `TranscriptionPipeline.swift` | Pipeline protocol + Offline/Cloud implementations |
| `TextPostProcessing.swift` | Post-processing protocol + Regex/LLM/Chained/OfflineLLM/ChainedOffline implementations |
| `CloudSTT.swift` | STTClient protocol + WAV encoder |
| `CloudLLM.swift` | LLMClient protocol |
| `HTTPHelper.swift` | Shared HTTP request validation + JSON parsing for providers |
| `RetryHelper.swift` | Exponential backoff retry for transient cloud API failures |
| `Logger.swift` | Structured os.Logger categories (general, audio, transcription, cloud, model, speaker) |
| `Providers/OpenAIProvider.swift` | OpenAI-compatible STT (Whisper) + LLM (GPT) |
| `Providers/AnthropicProvider.swift` | Anthropic Messages API (LLM only) |
| `Providers/GoogleProvider.swift` | Google Cloud Speech + Gemini |
| `APIConfiguration.swift` | Data models: APIEndpoint, AIMode, AISettings, Codable persistence |
| `KeychainHelper.swift` | Keychain CRUD for API keys |
| `SettingsView.swift` | Settings window UI (Audio tab, AI tab, endpoint editor) |
| `SettingsWindow.swift` | NSWindow management for Settings |
| `Transcriber.swift` | Actor wrapping sherpa-onnx offline recognizer + VAD |
| `AudioRecorder.swift` | AVAudioEngine mic capture with sample-rate conversion, voice processing |
| `InputDeviceManager.swift` | CoreAudio input device enumeration, UID-based persistence, hardware-change listener |
| `TextInserter.swift` | CGEvent keyboard simulation |
| `TextPostProcessor.swift` | Filler removal, dedup, whitespace normalization |
| `HotkeyManager.swift` | HotkeyConfig + configurable key event tap |
| `HotkeyRecorder.swift` | InlineHotkeyRecorder (menu bar) + HotkeyRecorderPanel (standalone) |
| `OverlayPanel.swift` | Floating waveform HUD (cloud-aware status text) |
| `ModelManager.swift` | Model download, extraction, discovery |
| `ModelVariant.swift` | Model configuration constants |
| `T5PostProcessor.swift` | Offline T5-small inference engine (encoder-decoder greedy decoding) |
| `T5Tokenizer.swift` | Pure-Swift SentencePiece Unigram tokenizer for T5 |
| `T5ModelManager.swift` | T5 model download from HuggingFace, discovery, deletion |
| `ONNXSession.swift` | Thin Swift wrapper around ORT C API (env, session, run) |
| `SpeakerVerifier.swift` | ECAPA-TDNN actor: embedding extraction, cosine similarity, enrollment |
| `SpeakerModelManager.swift` | Speaker model download from HuggingFace, discovery, deletion |
| `SpeakerEnrollment.swift` | Speaker enrollment data persistence (UserDefaults) |
| `AudioDucker.swift` | System volume duck/unduck during recording |
