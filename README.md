# Transcriber

A small macOS app. Drop an .m4a or .mp3 file onto its window; it transcribes the audio locally with whisper.cpp, shows the transcript, and saves it as a .txt file. No audio leaves the machine.

## Requirements

- macOS 13 or later, Apple silicon or Intel, with Xcode (for `swiftc`)
- whisper.cpp: `brew install whisper-cpp`
- A ggml model at `~/Library/Application Support/Transcriber/ggml-small.bin`:

```bash
mkdir -p "$HOME/Library/Application Support/Transcriber"
curl -L -o "$HOME/Library/Application Support/Transcriber/ggml-small.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

## Build

```bash
./build.sh
open Transcriber.app
```

The app decodes audio with the system `afconvert` and runs `whisper-cli` as a separate process.

## Licence

AGPL-3.0-or-later; see `LICENSE`. Third-party software it uses (whisper.cpp, ggml, the Whisper model weights) is MIT-licensed and is not bundled; see `NOTICE`.
