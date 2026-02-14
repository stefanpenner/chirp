# Chirp

**Offline voice-to-text for macOS.** Hold `fn`, speak, release — text appears at your cursor. No servers, no accounts, no data leaves your machine.

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

Everything runs locally. No network calls, no telemetry, no tracking. Your audio is never recorded or stored.
