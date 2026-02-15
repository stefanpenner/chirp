# Architecture

Chirp is a macOS 26+ menu bar app that performs offline speech-to-text. Hold the fn key, speak, release — transcribed text is typed into the focused app. All inference runs on-device via sherpa-onnx; audio never leaves the machine.

## Component Overview

```
┌─────────────────────────────────────────────────────┐
│  ChirpApp (SwiftUI MenuBarExtra)                    │
│  ┌───────────────────────────────────────────────┐  │
│  │  AppState (@Observable, @MainActor)           │  │
│  │  Status: downloading → loadingModel → ready   │  │
│  │          ⇄ recording → transcribing → ready   │  │
│  ├───────────────────────────────────────────────┤  │
│  │                                               │  │
│  │  HotkeyManager ──→ startRecording/stop        │  │
│  │                                               │  │
│  │  AudioRecorder ──→ [Float] chunks ──→         │  │
│  │  Transcriber (actor) ──→ text ──→             │  │
│  │  TextPostProcessor ──→ cleaned text ──→       │  │
│  │  TextInserter ──→ CGEvent keystrokes          │  │
│  │                                               │  │
│  │  ModelManager ── download/discover models     │  │
│  │  OverlayPanel ── floating HUD with waveform   │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────┐
│  CSherpaOnnx (C) │  sherpa-onnx + onnxruntime dylibs
└──────────────────┘
```

## State Machine

```
┌─────────────┐  model found  ┌──────────────┐ success ┌───────┐
│ downloading  │─────────────→│ loadingModel  │────────→│ ready │
│  (progress)  │              └──────────────┘ failure  │       │
└─────────────┘                      │         ┌──────→│       │
      │ failure                      ▼         │       └───┬───┘
      ▼                         ┌────────┐     │    fn press│
  ┌────────┐                    │ error  │     │           ▼
  │ error  │                    └────────┘     │    ┌───────────┐
  └────────┘                                   │    │ recording │
                                               │    └─────┬─────┘
                                               │    fn release│
                                               │          ▼
                                               │  ┌──────────────┐
                                               └──│ transcribing │
                                                  └──────────────┘
```

AppState owns all transitions. Only `ready → recording` (fn press) and `recording → transcribing` (fn release) are user-initiated; the rest are automatic.

## Audio Pipeline

1. **Capture** — `AudioRecorder` wraps AVAudioEngine. Converts hardware sample rate to 16 kHz mono Float32. The tap closure is `nonisolated static` to avoid `@MainActor` executor checks on the real-time audio thread.

2. **VAD** — `Transcriber.feedAudio()` pushes samples into Silero VAD. When it detects a speech-end boundary, the segment is extracted and transcribed. This gives natural sentence-level chunks.

3. **Transcription** — Offline recognizer (Parakeet TDT 0.6b v2 int8 or CTC variant) runs greedy-search decoding. The `Transcriber` actor serializes all C API access.

4. **Speculative preview** — Every 400ms, `peekTranscription()` runs inference on the last 5 seconds of pending audio. A generation counter (`commitGen`) discards stale previews when a real segment commits.

5. **Post-processing** — `TextPostProcessor.process()` strips fillers ("um", "uh"), deduplicates stutters ("the the" → "the"), normalizes whitespace, and capitalizes "I". Pure function, sub-millisecond.

6. **Insertion** — `TextInserter` posts `CGEvent` keystrokes via `CGEventKeyboardSetUnicodeString`, chunked to 20 UniChars per event. Requires Accessibility permission.

## Model System

`ModelVariant` enumerates available models (TDT, CTC) with download URLs, directory names, and check files. `ModelManager` handles:

- **Discovery**: searches App Support, working directory, parent dirs, and bundle resources
- **Download**: parallel URLSession tasks for model archive + VAD, with progress (0→0.7 download, 0.7→0.95 extraction, 0.95→1.0 validation)
- **Extraction**: `/usr/bin/tar xjf` to `~/Library/Application Support/Chirp/models/`

For development, `scripts/setup.sh` downloads models and dylibs to the repo (gitignored).

## Hotkey

`HotkeyManager` installs a `CGEvent` tap intercepting fn/Globe key events. It suppresses the key entirely (no emoji picker) and calls `onPress`/`onRelease` closures on the main actor via `Task { @MainActor in }`.

## Overlay

`OverlayPanel` manages a borderless `NSPanel` hosting a SwiftUI `IslandView`:
- Animated sine-wave waveform driven by audio level
- Committed text (white) + speculative text (gray)
- Conic gradient glow border
- Catppuccin-inspired color palette

## Testing

Protocol-based DI (`TranscriberProtocol`, `AudioRecording`, `TextInserting`) enables testing without hardware or ML models. Mock implementations live in `Tests/ChirpTests/Mocks.swift`. Tests use Swift Testing framework.

## Build & Distribution

**SPM** — Single `Chirp` target containing all Swift sources (including `Main.swift`). `CSherpaOnnx` C target wraps the sherpa-onnx header via modulemap. The executable links against `libsherpa-onnx-c-api` and `libonnxruntime` via rpath.

**Bazel** — Two-module split for testability:
- `ChirpLib` (module name `Chirp`): all sources except `Main.swift`, no `@main` entry point
- `ChirpMain`: only `Main.swift` with `@main`, imports `Chirp` and `Sparkle`
- `ChirpTests`: `swift_test` depending on `ChirpLib`
- Prebuilt `Sparkle.framework` imported via `apple_dynamic_framework_import`
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
| `Main.swift` | `@main` SwiftUI app entry point (menu bar UI) |
| `Protocols.swift` | DI boundaries: TranscriberProtocol, AudioRecording, TextInserting |
| `Transcriber.swift` | Actor wrapping sherpa-onnx offline recognizer + VAD |
| `AudioRecorder.swift` | AVAudioEngine mic capture with sample-rate conversion |
| `TextInserter.swift` | CGEvent keyboard simulation |
| `TextPostProcessor.swift` | Filler removal, dedup, whitespace normalization |
| `HotkeyManager.swift` | fn/Globe key event tap |
| `OverlayPanel.swift` | Floating waveform HUD |
| `ModelManager.swift` | Model download, extraction, discovery |
| `ModelVariant.swift` | Model metadata enum with persistence |
