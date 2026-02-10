# ollama-memory-embeddings

OpenClaw skill to use **Ollama as the embeddings server** for memory search.

**Distribution files** (what end users install) live in **`dist/`**.

## Install from this repo

From the project root:

```bash
bash dist/install.sh
```

For full user docs, options, and usage after install, see **[dist/README.md](dist/README.md)**.

## Repo layout

| Path | Purpose |
|------|--------|
| **dist/** | Installable skill (scripts, lib, SKILL.md, README, LICENSE.md). This is what gets copied to `~/.openclaw/skills/ollama-memory-embeddings`. |
| **tests/** | Unit and smoke tests; not part of the installed skill. |
| **.github/** | CI workflows. |
| **Development_docs/** | Design notes, roadmap, audit contract; not part of the installed skill. |
| **scripts/** | Maintainer scripts (e.g. version bump). |
| **.githooks/** | Git hooks; use `git config core.hooksPath .githooks` to enable. |

## Version (for OpenClaw directories)

3rd-party OpenClaw repositories/online directories can read the skill version from:

- **`dist/VERSION.txt`** — single line, semantic version (e.g. `1.0.0`). Also copied into the installed skill path.
- **`dist/SKILL.md`** — frontmatter `version: "1.0.0"`.

**Before you push:** if you changed anything in `dist/`, bump the version so directories see an update:

```bash
./scripts/bump-version.sh [patch|minor|major] --commit
```

Then push. The **pre-push hook** (after `git config core.hooksPath .githooks`) blocks the push if `dist/` changed but `dist/VERSION.txt` was not updated.

License: MIT. See [dist/LICENSE.md](dist/LICENSE.md).
