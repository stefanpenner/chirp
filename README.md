# Chirp

**Offline voice-to-text for macOS.** Hold `fn`, speak, release — text appears at your cursor. All transcription runs on-device — no accounts, no servers, no data leaves your machine.

## Features

- **Hold-to-talk** — Press `fn` to record, release to transcribe
- **Works everywhere** — Text is typed at your cursor in any app
- **Speculative preview** — See partial transcription as you speak
- **Fast** — Parakeet TDT 0.6b v2 with Silero VAD, all on-device
- **Menu bar app** — No dock icon, no clutter

## Install

```
./scripts/setup.sh      # download sherpa-onnx libs + model
swift run               # build and launch
```

The model downloads automatically on first launch (~240 MB compressed).

## Requirements

- macOS 26+
- Microphone permission
- Accessibility permission (for keystroke insertion)

## Privacy

All transcription runs locally. Your audio is processed in memory and never recorded or stored. No telemetry, no tracking, no data leaves your machine. Other than downloading the open-source models, Chirp requires no network access.
