# Chirp

**Offline voice-to-text for macOS.**
Hold `fn`, speak, release — text appears at your cursor. All transcription runs on-device — no accounts, no servers, no data leaves your machine.

## Features

- **Hold-to-talk** — Press `fn` to record, release to transcribe
- **Works everywhere** — Text is typed at your cursor in any app
- **Speculative preview** — See partial transcription as you speak
- **Fast** — Parakeet TDT 0.6b v2 with Silero VAD, all on-device
- **Menu bar app** — No dock icon, no clutter
- **Auto-updates** — Check for updates from the menu bar

## Install

### Download

Grab the latest DMG from [GitHub Releases](https://github.com/stefanpenner/chirp/releases), open it, and drag Chirp to Applications.

### Homebrew

```
brew install --cask stefanpenner/chirp/chirp
```

### Build from source

```
./scripts/setup.sh      # download sherpa-onnx libs + model
swift run               # build and launch
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

On first launch, Chirp downloads the speech recognition model (~240 MB). This is a one-time download. After that, Chirp works fully offline.

## Updating

Chirp checks for updates automatically. You can also check manually from the menu bar icon → **Check for Updates…**

Or with Homebrew:

```
brew upgrade chirp
```

## Troubleshooting

### "Chirp can't be opened because Apple cannot check it for malicious software"

This means the app isn't notarized yet. Right-click (or Control-click) the app and select **Open**. You'll see the same warning but with an **Open** button. You only need to do this once.

Alternatively, run:

```
xattr -cr /Applications/Chirp.app
```

### Text doesn't appear after transcription

Accessibility permission isn't enabled. Go to **System Settings → Privacy & Security → Accessibility** and make sure Chirp is listed and toggled on. You may need to remove and re-add it if you moved the app.

### No audio detected / microphone not working

- Check **System Settings → Privacy & Security → Microphone** and ensure Chirp is allowed
- Make sure your input device is set correctly in **System Settings → Sound → Input**

### Model download fails

Chirp needs internet access for the initial model download. If it fails, check your network connection and restart the app. The download resumes where it left off.

## Requirements

- macOS 26+
- ~500 MB disk space (app + model)
- Microphone permission
- Accessibility permission

## Privacy

All transcription runs locally. Your audio is processed in memory and never recorded or stored. No telemetry, no tracking, no data leaves your machine. Other than downloading the open-source models, Chirp requires no network access.

## Development

```
./scripts/setup.sh              # download sherpa-onnx libs + model
swift build                     # build
swift test                      # run tests
swift run                       # launch
./scripts/package.sh 0.2.0      # create DMG
```
