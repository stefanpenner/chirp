# Chirp

Offline voice-to-text for macOS. Hold **fn**, speak, text appears at your cursor. No cloud, no API keys — everything runs locally on your Mac.

Uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) with the Parakeet TDT 0.6b v2 model and Silero VAD for voice activity detection. The model auto-downloads on first launch (~240MB compressed, ~630MB extracted).

## Requirements

- macOS 14+
- Microphone permission
- Accessibility permission (for text insertion)

## Build & Run

```
make setup   # download sherpa-onnx libs + model (gitignored)
make build   # swift build
make run     # build and launch
```

## How It Works

Chirp is a menu bar app (no dock icon). Hold **fn** to record, release to stop. Audio is captured at 16kHz mono, segmented by Silero VAD, and transcribed offline via sherpa-onnx. The result is inserted at the current cursor position in any app.

A real-time waveform overlay is displayed while recording.

## Packaging

```
make package
```
# chirp
