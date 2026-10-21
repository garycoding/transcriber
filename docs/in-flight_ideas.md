<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# In-flight ideas

New ideas under consideration for Transcriber. Each entry is a question, not a commitment.

## Polishing with Claude through the user's own API key

**The idea.** Offer "Claude" in the "Polish with" menu beside LM Studio, Ollama and llama.cpp, and use it for polishing and summaries. The user enters their own Anthropic API key, created in the Claude Console; the app keeps it in the macOS Keychain and calls the Messages API (`https://api.anthropic.com/v1/messages`) directly with `URLSession`, and Anthropic bills that user per token.

**An API key is the only way to do this.** Anthropic's [support article on logging in](https://support.claude.com/en/articles/13189465) says that anyone "building a product, application, or tool for others" should "use API key authentication through Claude Console or a supported cloud provider", and it prohibits applications that "attempt to route third-party traffic against subscription limits". The [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) page and the [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) say the same: developers use API keys, and third-party products may not use a user's Claude.ai login or plan. API-key authentication is therefore the only approved route, and so the only route this app takes. These were ruled out:

- **Running the user's own signed-in Claude Code (`claude -p`).** It works technically, but it routes the app's requests against the user's Pro or Max plan, which the support article prohibits for a tool built for others.
- **The Claude desktop app.** It has no interface through which another app can send a prompt and read the reply; its `claude://` links only open a chat with the text filled in, and the user must press send.

**Findings (2026-10-21).** These were measured through `claude -p` on the developer's own Mac and plan, before the route above was ruled out; they show what Claude's models do with the app's prompt, and the API would run the same models.

- One 500-word window of the Kac lecture, with the app's own polish prompt: Sonnet answered in 16 seconds (484 words), Haiku in 19 seconds (483 words). At that rate the 8,699-word MIT lecture would take about 5 minutes, against 26 minutes 29 seconds with Gemma 4 12B in LM Studio on the same machine; this is an estimate from one window.
- Sonnet kept the speaker's words and corrected whisper's mishearings from their sense: "the freeze get too crowded on a dog" became "the fleas get too crowded on a dog", and "the name of dog dog free model" became "the dog flea model".

**Open questions.**

- **Privacy.** The app's promise is that nothing leaves the Mac. With Claude chosen, the transcript text (not the audio) goes to Anthropic. The menu would need a plain warning, and the README and the download page would say that text leaves the Mac only when Claude is chosen.
- **Cost.** The user pays per token; the app could show an estimate before a polish starts, from the transcript's length.
- **Entering the key.** Where the user pastes it, how the app checks it (one small request), and how it is replaced or removed from the Keychain.
- **Which model, and whether to offer the choice.** Sonnet and Haiku took about the same time on one window; quality across a whole recording is not compared.
- **Parallel windows.** The windows are independent once their boundaries are fixed, so several could run at once to shorten the polish, within the key's rate limits.
