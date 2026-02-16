# Chirp

**Free, Fast,  Offline voice-to-text for macOS.**
Hold `fn`, speak, release — text appears at your cursor. All transcription runs on-device — no accounts, no servers, no data leaves your machine.

<img width="310" height="257" alt="chirp-0 3 11-main" src="https://github.com/user-attachments/assets/de9c3483-3615-4f36-8415-998dc37e94cc" />

## Features

- **Hold-to-talk** — Press `fn` to record, release to transcribe, hotkey can be changed
- **Works everywhere** — Text is typed at your cursor in any app
- **Speculative preview** — See partial transcription as you speak
- **Fast** — Parakeet TDT 0.6b v2 with Silero VAD, all on-device
- **Menu bar app** — No dock icon, no clutter
- **Auto-updates** — Check for updates from the menu bar

<img width="272" height="234" alt="chirp-0 3 11-hotkey-select" src="https://github.com/user-attachments/assets/2641c92a-664e-4e2e-aaf3-5b5781f850a7" />
<img width="280" height="253" alt="chirp-0 3 11-hotkey-selected" src="https://github.com/user-attachments/assets/7bf548a0-2b1c-4cf9-862c-851bd559c7a0" />
<img width="268" height="226" alt="chirp-0 3 11-hotkey-saved" src="https://github.com/user-attachments/assets/c72f5126-2551-4f8d-9da8-d7e58a683423" />

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

All transcription runs locally. Your audio is processed in memory and never recorded or stored. No telemetry, no tracking, no data leaves your machine. Other than downloading the open-source models, Chirp requires no network access.

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
