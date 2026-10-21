<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# Transcriber

A small macOS app: drop an .m4a or .mp3 file onto its window and it transcribes the audio locally with whisper.cpp, shows the transcript, and saves it as a .txt file. No audio leaves the machine.

## Status

Version 0.1.0, not yet released. The transcription path is verified on a generated .m4a; dragging a file onto the window, .mp3 input and the save dialog are not yet verified.

## Run

Requirements: macOS 13 or later, Xcode (for `swiftc`), whisper.cpp and a ggml model.

```bash
brew install whisper-cpp
mkdir -p "$HOME/Library/Application Support/Transcriber"
curl -L -o "$HOME/Library/Application Support/Transcriber/ggml-small.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
./build.sh
open Transcriber.app
```

The app decodes audio with the system `afconvert` and runs `whisper-cli` as a separate process. A release attaches the built, ad-hoc-signed app as a zip; it still needs whisper.cpp and the model installed as above.

## Configuration

There is no configuration file. Two paths are fixed:

| Item | Location |
|---|---|
| `whisper-cli` | `/opt/homebrew/bin/whisper-cli`, else `/usr/local/bin/whisper-cli` |
| Model | `~/Library/Application Support/Transcriber/ggml-small.bin` |

## Releasing

Tag-driven, from `main`, as the handbook's [`releases.md`](https://github.com/ParkviewLab/handbook/blob/main/docs/releases.md) describes. The version lives in `VERSION.txt` only. The release workflow builds the app on a macOS runner and attaches `Transcriber-<version>-macos.zip` to the GitHub Release.

## Licence

`AGPL-3.0-or-later` for the code, `CC-BY-4.0` for the documentation; see [`LICENSING.md`](LICENSING.md).

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
