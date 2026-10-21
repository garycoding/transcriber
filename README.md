<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# Transcriber

A small macOS app: drop an .m4a or .mp3 file onto its window and it transcribes the audio locally with whisper.cpp, shows the transcript, and saves it as a .txt file. No audio leaves the machine.

## Status

Version 0.1.0, not yet released. Verified: the transcription path on a generated .m4a, and the first-launch model download with its checksum. Not yet verified: dragging a file onto the window, .mp3 input and the save dialog.

## Formats

Audio: mp3, m4a, aac, wav, aiff, caf, flac, ac3, mp2. Video: mp4, mov, m4v, 3gp, from which the first audio track is used. macOS decodes them with its own `afconvert`, which writes a temporary 16 kHz mono WAV (about 115 MB per hour of audio) that is deleted afterwards. mkv, webm, avi, wmv and Ogg files are not supported.

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

`build.sh` first builds a self-contained `whisper-cli` from the pinned whisper.cpp release (`scripts/build-whisper`) and bundles it in the app. The app decodes audio with the system `afconvert` and runs the bundled `whisper-cli` as a separate process, without letting it carry earlier text forward (`-mc 0`): left to itself on a long recording, whisper tends to stop punctuating.

## Polishing with a local model

If LM Studio (port 1234), Ollama (port 11434) or llama.cpp's `llama-server` (port 8080) is running on the same Mac, the app lists its models in the "Polish with" menu. Choose one, and each later transcription gets a second pass: the model adds punctuation, corrects clear mishearings, removes stutters and divides the text into paragraphs. The default is "None", and the choice is remembered.

The transcript stays on show, and can be copied or saved, while the pass runs. The polished version appears beside it and grows as the model works, with its own progress bar, a time estimate, and its own Copy and Save buttons.

The pass works in independent calls, each a fresh conversation. A window of about 500 words, beginning and ending at sentence ends, is given to the model, which returns it as paragraphs of its own choosing. The app finds where each paragraph ends in the original words, keeps all but the last (the thought may continue), and starts the next window at the word after the last one kept, so nothing is repeated or cut mid-sentence. An answer that cannot be matched to the text is asked for once more; if that fails too, whole sentences of the original are kept as transcribed and shown in orange. Each rejected answer is written to `~/Library/Logs/Transcriber/polish-rejected.log`, on this Mac only, so that it can be looked at. Reasoning is switched off in the request, because a reasoning model spends most of its time thinking.

The "Summarise" button, which needs a chosen model, adds a third pane with a one-line description of the recording and a summary. It works on the polished text if there is any, in blocks of about 1,000 words, each summarised with the summaries of the blocks before it as notes, and then the block summaries are summarised as a whole. It runs only when the button is pressed.

The app contacts only `127.0.0.1`; the transcript never leaves the Mac. A model can change a word it should not, so read the polished text against the transcript before relying on it. The window shows the length of the audio.

The generated text (the transcript, the polished text and the summary) cannot be edited in the app; select it, copy it, or save it.

One file is held at a time: after a transcription, the window accepts no further file until "Discard Transcription" is pressed, which clears both versions and cancels a polish in progress.

## Playing along with the text

When a file is dropped, or a saved session opened, the original audio or video can be played in the window, with the controls above the text: play and pause, buttons to jump back or forward 10 seconds, a slider to scrub, the time, a speed menu (0.5× to 2×), and, for a video, the picture (the Video button hides it). While it plays, or as you scrub, the sentence being spoken is highlighted in both panes, and both scroll to keep it in view. The polished pane follows by sentence, found by the paragraph's place in the original words and each sentence's share of its length, so it is close and not exact. Scrolling a pane by hand turns "Follow" off, so that the text stays where you put it; the Follow button turns it on again. Double-clicking a word in either pane highlights its sentence in both, moves the player there, and scrolls the other pane to match. A saved session is unpacked to play, into a folder the app clears the next time it starts, so opening a session with a large video takes a moment.

## Saving a session

"Save Session…" (beside "Discard Transcription") writes one zip file holding the whole transcription: `session.json` (the text exactly as shown, whisper's segments with their start and end times, the timings, the models used and the app version), the text as plain files (`transcript.txt`, `polished.txt`, `summary.txt`) for use in another editor, and the whole original audio or video file under `original/`. Dropping such a zip on the app opens it as it was saved, with the text as saved. A zip counts as the app's own only if it holds `session.json` in the app's format, only the files above, and one original file; any other zip is refused. A file larger than 2 GB asks for confirmation before saving, since the zip holds all of it.

## Configuration

There is no configuration file. The speech model is stored at `~/Library/Application Support/Transcriber/ggml-small.bin`; delete it to have the app download it again.

## Releasing

Tag-driven, from `main`, as the handbook's [`releases.md`](https://github.com/ParkviewLab/handbook/blob/main/docs/releases.md) describes. The version lives in `VERSION.txt` only. The release workflow builds the app on a macOS runner and attaches `Transcriber-<version>-macos.dmg` to the GitHub Release.

## Licence

`AGPL-3.0-or-later` for the code, `CC-BY-4.0` for the documentation; see [`LICENSING.md`](LICENSING.md).

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
