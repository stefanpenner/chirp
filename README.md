# Chirp

**Offline voice-to-text for macOS.** Hold `fn`, speak, release — text appears at your cursor.

## Privacy First

Chirp runs entirely on your Mac. There are no servers, no API keys, no accounts, no telemetry, and no tracking. Your voice is processed locally and never recorded. Nothing leaves your machine — ever.

Use it at work, at home, or anywhere privacy matters.

## Features

- **Hold-to-talk** — Press `fn` to record, release to transcribe
- **Works everywhere** — Text is inserted at your cursor in any app
- **Real-time feedback** — Live waveform overlay while you speak
- **Fast and accurate** — Powered by [Parakeet TDT 0.6b v2](https://nvidia.github.io/NeMo/blogs/2025/01/parakeet-tdt-0.6b-v2/) with [Silero VAD](https://github.com/snakers4/silero-vad)
- **Lightweight** — Lives in your menu bar, no dock icon, no clutter
- **Zero configuration** — Model auto-downloads on first launch

## Requirements

- macOS 14+
- Microphone permission
- Accessibility permission (for text insertion)

## Getting Started

```
make setup   # download sherpa-onnx libs + model
make build   # compile
make run     # build and launch
```

The speech model downloads automatically on first launch (~240MB compressed, ~630MB on disk).

## How It Works

Chirp captures audio at 16kHz mono, detects speech using Silero VAD, and transcribes it offline with [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). The transcribed text is inserted at your cursor position via the system clipboard. A real-time waveform overlay provides visual feedback while recording.

## Packaging

```
make package
```
