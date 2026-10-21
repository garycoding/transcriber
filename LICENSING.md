# Licensing

Copyright © 2026 Gary Frattarola.

## How this project is licensed

Transcriber is open source under `AGPL-3.0-or-later`. You may use, modify, and distribute it under those terms. The full text is in [`LICENSE`](LICENSE) and [`LICENSES/`](LICENSES/). There is no commercial alternative.

## Per-bucket licensing

Different kinds of content carry different licenses (encoded in [`REUSE.toml`](REUSE.toml) and per-file SPDX headers):

| Bucket | License |
|---|---|
| Code, build scripts, configs, the version pin | `AGPL-3.0-or-later` |
| Documentation (`docs/`, `README.md`, this file) | `CC-BY-4.0` |

## Third-party software

Transcriber bundles no third-party software. At run time it starts, as a separate process, the following MIT-licensed software, which the user installs:

- whisper.cpp (`whisper-cli`), MIT, <https://github.com/ggml-org/whisper.cpp>
- ggml, MIT, <https://github.com/ggml-org/ggml>
- the OpenAI Whisper model weights, as ggml conversions, MIT, <https://github.com/openai/whisper>

## REUSE compliance

This repo is [REUSE](https://reuse.software/)-compliant. Every file has a license via an SPDX header or a `REUSE.toml` annotation. Verify with:

```bash
uvx --from "reuse[charset-normalizer]" reuse lint
```

Any new file needs an SPDX header or a `REUSE.toml` entry, or the lint breaks.

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
