# Vox

A native macOS voice assistant. Hold a key, speak, and your words land as text in whatever app you're in. Built to grow from dictation-anywhere into a voice layer that performs real actions on your Mac.

> Status: **M0 (scaffold)**. Menu-bar app + global hotkey working. Dictation lands next.

## Why

Most voice tools are either cloud-locked dictation or single-purpose assistants. Vox is a local-first voice layer for macOS: fast dictation everywhere, growing toward "say it, and your Mac does it."

## Architecture (the cascade)

```
mic -> capture/clean -> VAD/endpoint -> STT -> brain (LLM) -> action/insert
```

Vox is built one stage at a time:

- **M0 Scaffold** (done): menu-bar app, permission-free global hotkey.
- **M1 Dictation:** push-to-talk -> cloud STT -> insert text into the focused app.
- **M2 Cleanup:** Claude formats the transcript; raw vs cleaned modes.
- **M4 Local mode:** on-device STT (WhisperKit) for offline, private dictation.
- **M3 Actions:** spoken commands -> Claude tool-calling -> real macOS actions.

## Build and run

Requires Swift (Command Line Tools) on Apple Silicon macOS 14+.

```sh
make run     # build, bundle into Vox.app, and launch
```

The app lives in the menu bar (no Dock icon). Press **Cmd + Shift + Space** to toggle it.

## Stack

Swift + SwiftUI/AppKit, Swift Package Manager. Carbon hotkeys, AVFoundation for audio, CoreML/WhisperKit for on-device speech (later).
