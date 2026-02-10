# ollama-memory-embeddings

Installable OpenClaw skill to use **Ollama as the embeddings server** for
memory search (OpenAI-compatible `/v1/embeddings`).

> **Embeddings only** — chat/completions routing is not affected.

## Features

- Interactive embedding model selection:
  - `embeddinggemma` (default — closest to OpenClaw built-in)
  - `nomic-embed-text` (strong quality, efficient)
  - `all-minilm` (smallest/fastest)
  - `mxbai-embed-large` (highest quality, larger)
- Optional import of a local embedding GGUF into Ollama (`ollama create`)
  - Detects: embeddinggemma, nomic-embed, all-minilm, mxbai-embed GGUFs
- Model name normalization (handles `:latest` tag automatically)
- Surgical OpenClaw config update (`agents.defaults.memorySearch`)
- Post-write config sanity check
- Smart gateway restart (detects available restart method)
- Two-step verification: model existence + endpoint response
- Non-interactive mode for automation (GGUF import is opt-in)
- Optional memory reindex during install (`--reindex-memory auto|yes|no`)
- Idempotent drift enforcement (`enforce.sh`)
- Optional auto-heal watchdog (`watchdog.sh`, launchd on macOS)

## Install

```bash
bash ~/.openclaw/skills/ollama-memory-embeddings/install.sh
```

Bulletproof install (enforce + watchdog):

```bash
bash ~/.openclaw/skills/ollama-memory-embeddings/install.sh \
  --non-interactive \
  --model embeddinggemma \
  --reindex-memory auto \
  --install-watchdog \
  --watchdog-interval 60
```

From repo:

```bash
bash skills/ollama-memory-embeddings/install.sh
```

## Non-interactive example

```bash
bash ~/.openclaw/skills/ollama-memory-embeddings/install.sh \
  --non-interactive \
  --model embeddinggemma \
  --reindex-memory auto \
  --import-local-gguf yes   # explicit opt-in; "auto" = "no" in non-interactive
```

## Verify

```bash
~/.openclaw/skills/ollama-memory-embeddings/verify.sh
~/.openclaw/skills/ollama-memory-embeddings/verify.sh --verbose   # dump raw response on failure
```

## Drift guard and self-heal

One-time check/heal:

```bash
~/.openclaw/skills/ollama-memory-embeddings/watchdog.sh --once --model embeddinggemma
```

Manual enforce (idempotent):

```bash
~/.openclaw/skills/ollama-memory-embeddings/enforce.sh --model embeddinggemma
```

Install launchd watchdog (macOS):

```bash
~/.openclaw/skills/ollama-memory-embeddings/watchdog.sh \
  --install-launchd \
  --model embeddinggemma \
  --interval-sec 60
```

Remove launchd watchdog:

```bash
~/.openclaw/skills/ollama-memory-embeddings/watchdog.sh --uninstall-launchd
```

## Important: re-embed when changing model

If you switch embedding model, existing vectors may be incompatible with the new
vector space. Rebuild/re-embed your memory index after model changes to avoid
retrieval quality regressions.

Installer behavior:
- `--reindex-memory auto` (default): reindex only when embedding fingerprint changed (`provider`, `model`, `baseUrl`, `apiKey presence`).
- `--reindex-memory yes`: always run `openclaw memory index --force --verbose`.
- `--reindex-memory no`: never reindex automatically.

Notes:
- `enforce.sh --check-only` treats apiKey drift as **missing apiKey** (empty), not strict equality to `"ollama"`.
- Backups are created only when config changes are actually written.
- Legacy config fallback supported: if canonical `agents.defaults.memorySearch` is missing,
  scripts read known legacy paths and mirror updates for compatibility.
