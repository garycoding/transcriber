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

The built app bundles `whisper-cli`, built from whisper.cpp (MIT, <https://github.com/ggml-org/whisper.cpp>), which includes ggml (MIT). The whisper.cpp licence text is shipped inside the app as `Contents/Resources/whisper.cpp-LICENSE.txt`. It is run as a separate process.

The app downloads, on first launch, the OpenAI Whisper "small" model as a ggml conversion (MIT, <https://github.com/openai/whisper>) from <https://huggingface.co/ggerganov/whisper.cpp>. The model is not part of this repository or of the app bundle.

## REUSE compliance

This repo is [REUSE](https://reuse.software/)-compliant. Every file has a license via an SPDX header or a `REUSE.toml` annotation. Verify with:

```bash
uvx --from "reuse[charset-normalizer]" reuse lint
```

Any new file needs an SPDX header or a `REUSE.toml` entry, or the lint breaks.

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
