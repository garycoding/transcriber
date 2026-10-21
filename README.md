<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# Transcriber

A small macOS app: drop an .m4a or .mp3 file onto its window and it transcribes the audio locally with whisper.cpp, shows the transcript, and saves it as a .txt file. No audio leaves the machine.

## Status

Version 0.1.0, not yet released. Verified: the transcription path on a generated .m4a, and the first-launch model download with its checksum. Not yet verified: dragging a file onto the window, .mp3 input and the save dialog.

## Install

Apple silicon Macs only, macOS 13 or later.

1. Download `Transcriber-<version>-macos.dmg` from the [Releases](https://github.com/garycoding/transcriber/releases) page, open it, and drag `Transcriber.app` onto the Applications shortcut.
2. The app is not signed with an Apple Developer ID, so macOS quarantines the download. Clear that once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Transcriber.app
```

3. Open the app. On first launch it downloads the speech model (465 MB) and shows the progress at the top of the window; the download happens once and the model is verified against a checksum. After that the app works offline.

## Build from source

Requirements: Xcode (for `swiftc`) and cmake.

```bash
./build.sh
open Transcriber.app
```

`build.sh` first builds a self-contained `whisper-cli` from the pinned whisper.cpp release (`scripts/build-whisper`) and bundles it in the app. The app decodes audio with the system `afconvert` and runs the bundled `whisper-cli` as a separate process.

## Polishing with a local model

If LM Studio (port 1234), Ollama (port 11434) or llama.cpp's `llama-server` (port 8080) is running on the same Mac, the app lists its models in the "Polish with" menu. Choose one, and each later transcription gets a second pass: the model adds punctuation, corrects clear mishearings, removes stutters and divides the text into paragraphs. The default is "None", and the choice is remembered.

The transcript stays on show, and can be copied or saved, while the pass runs. The polished version appears beside it and grows as the model works, with its own progress bar, a time estimate, and its own Copy and Save buttons.

The pass works in independent calls, each a fresh conversation. A call is given the next 500 words or so and returns its first three paragraphs; the app keeps them, strips the lines they cover from the front of the transcript, and repeats with the rest. A paragraph that reaches the end of the window is left for the next call, since it may be cut off. When no paragraph of an answer fits the original (its length differs by more than a quarter, or its markers are wrong), the first lines of the window are kept as transcribed. Reasoning is switched off in the request, because a reasoning model spends most of its time thinking.

The app contacts only `127.0.0.1`; the transcript never leaves the Mac. A model can change a word it should not, so read the polished text against the transcript before relying on it.

One file is held at a time: after a transcription, the window accepts no further file until "Discard Transcription" is pressed, which clears both versions and cancels a polish in progress.

## Configuration

There is no configuration file. The speech model is stored at `~/Library/Application Support/Transcriber/ggml-small.bin`; delete it to have the app download it again.

## Releasing

Tag-driven, from `main`, as the handbook's [`releases.md`](https://github.com/ParkviewLab/handbook/blob/main/docs/releases.md) describes. The version lives in `VERSION.txt` only. The release workflow builds the app on a macOS runner and attaches `Transcriber-<version>-macos.dmg` to the GitHub Release.

## Licence

`AGPL-3.0-or-later` for the code, `CC-BY-4.0` for the documentation; see [`LICENSING.md`](LICENSING.md).

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
