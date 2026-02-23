# Chirp


**Free, Fast, Offline voice-to-text for macOS.**
Hold `fn`, speak, release — text appears at your cursor. Works fully offline by default — no accounts, no servers, no data leaves your machine. Optionally connect cloud providers for higher-accuracy transcription and LLM post-processing.

<img width="680" height="151" alt="chirp-0 3 16-transcribing" src="https://github.com/user-attachments/assets/a4cb6c75-6b77-486b-9aec-8ea2d688d453" />

## Install

### Download

Grab the latest DMG from [GitHub Releases](https://github.com/stefanpenner/chirp/releases), open it, and drag Chirp to Applications.

### Homebrew

```
brew install --cask stefanpenner/chirp/chirp
```

### Build from source

```
brew install bazelisk    # install Bazel via Bazelisk
bazel run //:Chirp       # build and launch
```

## Features
<img width="310" height="257" alt="chirp-0 3 11-main" src="https://github.com/user-attachments/assets/de9c3483-3615-4f36-8415-998dc37e94cc" />


- **Hold-to-talk** — Press `fn` (configurable) to record, release to transcribe
- **Works everywhere** — Text is typed at your cursor in any app
- **Speculative preview** — See partial transcription as you speak (even in cloud mode)
- **Fast** — Parakeet TDT 0.6b v2 with Silero VAD, all on-device
- **AI Modes** — Named pipeline presets you can switch from the menu bar. Ships with "Offline" and "Offline + Fixup"; create your own with cloud STT, LLM post-processing, or any combination
- **Cloud providers** — Optional support for OpenAI, Anthropic, and Google APIs (plus any OpenAI-compatible gateway like OpenRouter)
- **Menu bar app** — No dock icon, no clutter
- **Auto-updates** — Check for updates from the menu bar

## Setup

### Permissions

Chirp needs two permissions on first launch:

1. **Microphone** — macOS will prompt automatically. Click Allow.
2. **Accessibility** — Required for typing text at your cursor. Go to:
   - **System Settings → Privacy & Security → Accessibility**
   - Click the `+` button, find Chirp in Applications, and add it
   - Make sure the toggle is enabled

If Chirp can transcribe but text doesn't appear, Accessibility permission is missing.

### Model download

On first launch, Chirp downloads the Parakeet TDT 0.6b v2 speech recognition model (~460 MB download, ~631 MB on disk). This is a one-time download stored in `~/Library/Application Support/Chirp/`. After that, Chirp works fully offline.

## Updating

Chirp checks for updates automatically. You can also check manually from the menu bar icon → **Check for Updates…**

Or with Homebrew:

```
brew upgrade chirp
```

## Troubleshooting

### Text doesn't appear after transcription

Accessibility permission isn't enabled. Go to **System Settings → Privacy & Security → Accessibility** and make sure Chirp is listed and toggled on. You may need to remove and re-add it if you moved the app.

### No audio detected / microphone not working

- Check **System Settings → Privacy & Security → Microphone** and ensure Chirp is allowed
- Make sure your input device is set correctly in **System Settings → Sound → Input**

### Model download fails

Chirp needs internet access for the initial model download. If it fails, check your network connection and restart the app. The download resumes where it left off.

## Requirements

- macOS 26+
- ~700 MB disk space (app + model)
- Microphone permission
- Accessibility permission

## Privacy

In the default "Offline" mode, all transcription runs locally. Your audio is processed in memory and never recorded or stored. No telemetry, no tracking, no data leaves your machine.

When you opt into cloud AI modes, audio or text is sent to the provider you configure (OpenAI, Anthropic, Google, or a custom gateway). No data is sent unless you explicitly create and activate a cloud AI mode.

## Acknowledgments

Chirp is built on these open-source projects:

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — speech recognition engine (Apache 2.0)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) — model inference runtime (MIT)
- [NVIDIA Parakeet TDT 0.6b v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) — speech-to-text model ([CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/))
- [Silero VAD](https://github.com/snakers4/silero-vad) — voice activity detection (MIT)
- [Sparkle](https://github.com/sparkle-project/Sparkle) — auto-update framework (MIT)

Full license texts are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).

## Development

Install [Bazelisk](https://github.com/bazelbuild/bazelisk), which reads `.bazelversion` and fetches the right Bazel automatically:

```
brew install bazelisk
bazel build //:Chirp                  # build
bazel run //:Chirp                    # build and launch
bazel test //...                      # run tests
bazel run //:package -- 0.3.0         # create signed DMG
```
