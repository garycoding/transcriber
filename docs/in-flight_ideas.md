<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# In-flight ideas

New ideas under consideration for Transcriber. Each entry is a question, not a commitment.

## Polishing with Claude through the user's own Claude Code

**The idea.** When the user has Claude Code installed and signed in, offer "Claude" in the "Polish with" menu beside LM Studio, Ollama and llama.cpp, and use it for polishing and summaries. The app would run the user's own `claude` program as a child process, as it runs whisper-cli, and the usage would count against the user's own Claude plan. The Claude desktop app cannot serve: it has no interface through which another app can send a prompt and read the reply, and its `claude://` links only open a chat with the text filled in.

**Findings (2026-10-21, Claude Code 2.1.305, on an M5 MacBook Air with a Max plan).**

- Claude Code installs at `~/.local/bin/claude`, which is not on the search path an app opened from the Dock receives, so the app would look for it there itself.
- `claude auth status` reports whether the user is signed in, and with which kind of account.
- The program needs `HOME` and `USER` in its environment; without `USER` it cannot find its sign-in and answers "Not logged in".
- By default `claude -p` loads the user's own settings, hooks and MCP servers. On the test machine that start-up took 100 to 300 seconds before the model answered. With `--setting-sources ""` and `--strict-mcp-config` the same request took 3 seconds. `--tools ""` leaves Claude no tools, so it can only answer, and `--no-session-persistence` keeps the calls out of the user's session history. `--bare` is not usable: it skips the keychain, where the sign-in is kept.
- The call that worked: `claude -p --output-format json --tools "" --setting-sources "" --strict-mcp-config --no-session-persistence --model sonnet --system-prompt "<the polish prompt>"`, with the window's text on standard input and the reply read from the JSON's `result`.
- One 500-word window of the Kac lecture, with the app's own polish prompt: Sonnet answered in 16 seconds (484 words), Haiku in 19 seconds (483 words). At that rate the 8,699-word MIT lecture would take about 5 minutes, against 26 minutes 29 seconds with Gemma 4 12B in LM Studio on the same machine; this is an estimate from one window.
- Sonnet kept the speaker's words and corrected whisper's mishearings from their sense: "the freeze get too crowded on a dog" became "the fleas get too crowded on a dog", and "the name of dog dog free model" became "the dog flea model".

**Open questions.**

- **Anthropic's terms (first, and unresolved).** The [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) page says developers building products "should use API key authentication" and may not "route requests through Free, Pro, or Max plan credentials on behalf of their users"; the same page says this "does not prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription", and that a product running Claude Code must leave the binary unmodified and must not pay for, resell or intermediate the user's usage. The [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) says that, unless approved, third-party developers may not "offer claude.ai login or rate limits for their products". Running the user's own installed and signed-in program fits the second statement better than the first, but that is a reading, not a ruling. Ask Anthropic before shipping it to anyone else; the Messages API with the user's own API key is the route that is clearly permitted.
- **Privacy.** The app's promise is that nothing leaves the Mac. With Claude chosen, the transcript text (not the audio) goes to Anthropic. The menu would need a plain warning, and the README and the download page would say that text leaves the Mac only when Claude is chosen.
- **Which model, and whether to offer the choice.** Sonnet and Haiku took about the same time on one window; quality across a whole recording is not compared.
- **Parallel windows.** The windows are independent once their boundaries are fixed, so several could run at once to shorten the polish further, at the cost of usage arriving faster against the user's plan limits.
