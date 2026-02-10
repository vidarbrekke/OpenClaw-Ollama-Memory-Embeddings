#!/usr/bin/env bash
# Install and configure OpenClaw memory embeddings via Ollama.
# Can run from repo path or from ~/.openclaw/skills/ollama-memory-embeddings.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
SKILLS_DIR="${OPENCLAW_DIR}/skills/ollama-memory-embeddings"

MODEL="${EMBEDDING_MODEL:-embeddinggemma}"
IMPORT_LOCAL_GGUF="${IMPORT_LOCAL_GGUF:-auto}"  # auto|yes|no
IMPORT_MODEL_NAME="${IMPORT_MODEL_NAME:-embeddinggemma-local}"
NON_INTERACTIVE=0
SKIP_RESTART=0
INSTALL_WATCHDOG=0
WATCHDOG_INTERVAL=60
REINDEX_MEMORY="auto" # auto|yes|no
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_DIR}/openclaw.json}"

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Configures OpenClaw memory search to use Ollama as the embeddings server
(OpenAI-compatible /v1/embeddings). This is embeddings only — chat/completions
routing is not affected.

Options:
  --model <id>                embeddinggemma | nomic-embed-text | all-minilm | mxbai-embed-large
  --import-local-gguf <mode>  auto | yes | no   (default: auto)
                              In non-interactive mode, auto is treated as "no"
                              unless explicitly set to "yes".
  --import-model-name <name>  model name to create in Ollama (default: embeddinggemma-local)
  --openclaw-config <path>    OpenClaw config path (default: ~/.openclaw/openclaw.json)
  --non-interactive           do not prompt; use supplied/default values
  --skip-restart              do not restart OpenClaw gateway
  --install-watchdog          install drift auto-heal watchdog via launchd (macOS)
  --watchdog-interval <sec>   watchdog check interval in seconds (default: 60)
  --reindex-memory <mode>     auto | yes | no (default: auto)
                              auto: reindex only if embedding fingerprint changed
  --help                      show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --import-local-gguf) IMPORT_LOCAL_GGUF="$2"; shift 2 ;;
    --import-model-name) IMPORT_MODEL_NAME="$2"; shift 2 ;;
    --openclaw-config) CONFIG_PATH="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-restart) SKIP_RESTART=1; shift ;;
    --install-watchdog) INSTALL_WATCHDOG=1; shift ;;
    --watchdog-interval) WATCHDOG_INTERVAL="$2"; shift 2 ;;
    --reindex-memory) REINDEX_MEMORY="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found in PATH."
    exit 1
  }
}

validate_model() {
  case "$1" in
    embeddinggemma|nomic-embed-text|all-minilm|mxbai-embed-large) return 0 ;;
    *) echo "ERROR: invalid model '$1'"; exit 1 ;;
  esac
}

validate_import_mode() {
  case "$1" in
    auto|yes|no) return 0 ;;
    *) echo "ERROR: invalid import mode '$1' (expected auto|yes|no)"; exit 1 ;;
  esac
}

validate_reindex_mode() {
  case "$1" in
    auto|yes|no) return 0 ;;
    *) echo "ERROR: invalid reindex mode '$1' (expected auto|yes|no)"; exit 1 ;;
  esac
}

# Normalize model name: add :latest if no tag present.
# Ollama list prints "model:tag"; the embeddings API also expects the tagged form.
normalize_model() {
  local m="$1"
  if [[ "$m" != *:* ]]; then
    echo "${m}:latest"
  else
    echo "$m"
  fi
}

ollama_running() {
  curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1
}

# Search for any embedding GGUF (embeddinggemma, nomic-embed, all-minilm, mxbai-embed).
# Currently scoped to known node-llama-cpp / OpenClaw cache directories.
find_local_embedding_gguf() {
  local dirs=(
    "$HOME/.node-llama-cpp/models"
    "$HOME/.cache/node-llama-cpp/models"
    "$HOME/.cache/openclaw/models"
  )
  local d
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' file; do
      echo "$file"
      return 0
    done < <(find "$d" -type f \( \
      -name "*embeddinggemma*.gguf" -o \
      -name "*nomic-embed*.gguf" -o \
      -name "*all-minilm*.gguf" -o \
      -name "*mxbai-embed*.gguf" \
    \) -print0 2>/dev/null)
  done
  return 1
}

gguf_matches_selected_model() {
  local gguf="$1"
  local model="$2"
  case "$model" in
    embeddinggemma) [[ "$gguf" == *embeddinggemma* ]] ;;
    nomic-embed-text) [[ "$gguf" == *nomic-embed* ]] ;;
    all-minilm) [[ "$gguf" == *all-minilm* ]] ;;
    mxbai-embed-large) [[ "$gguf" == *mxbai-embed* ]] ;;
    *) return 1 ;;
  esac
}

guess_model_from_gguf() {
  local gguf="$1"
  if [[ "$gguf" == *embeddinggemma* ]]; then
    echo "embeddinggemma"
  elif [[ "$gguf" == *nomic-embed* ]]; then
    echo "nomic-embed-text"
  elif [[ "$gguf" == *all-minilm* ]]; then
    echo "all-minilm"
  elif [[ "$gguf" == *mxbai-embed* ]]; then
    echo "mxbai-embed-large"
  else
    echo "unknown"
  fi
}

prompt_model_if_needed() {
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    return 0
  fi
  echo "Choose embedding model for Ollama:"
  echo "  1) embeddinggemma (default — closest to OpenClaw built-in)"
  echo "  2) nomic-embed-text (strong quality, efficient)"
  echo "  3) all-minilm (smallest/fastest)"
  echo "  4) mxbai-embed-large (highest quality, larger)"
  printf "Selection [1-4, default 1]: "
  read -r pick
  case "${pick:-1}" in
    1) MODEL="embeddinggemma" ;;
    2) MODEL="nomic-embed-text" ;;
    3) MODEL="all-minilm" ;;
    4) MODEL="mxbai-embed-large" ;;
    *) echo "Invalid selection."; exit 1 ;;
  esac
}

# Check if model exists in Ollama (handles :latest normalization).
model_exists_in_ollama() {
  local model_tagged
  model_tagged="$(normalize_model "$1")"
  # Also check untagged form: ollama list may show either
  ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qE "^(${1}|${model_tagged})$" 2>/dev/null
}

import_gguf_to_ollama() {
  local gguf="$1"
  local name="$2"
  local tmp
  tmp="$(mktemp)"
  echo "FROM \"$gguf\"" > "$tmp"
  set +e
  ollama create "$name" -f "$tmp"
  local status=$?
  set -e
  rm -f "$tmp"
  return "$status"
}

# Detect gateway restart method.
restart_gateway() {
  # Try openclaw gateway restart first
  if openclaw gateway restart 2>/dev/null; then
    return 0
  fi

  echo ""
  echo "WARNING: 'openclaw gateway restart' did not succeed."
  echo "Please restart the gateway manually using one of:"
  echo ""
  # macOS launchd
  if [ "$(uname)" = "Darwin" ] && launchctl list 2>/dev/null | grep -q openclaw 2>/dev/null; then
    local uid
    uid="$(id -u)"
    echo "  macOS (launchd):  launchctl kickstart -k gui/${uid}/bot.molt.gateway"
  fi
  # Linux systemd
  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled openclaw-gateway 2>/dev/null; then
    echo "  Linux (systemd):  systemctl --user restart openclaw-gateway"
  fi
  echo "  Manual:           stop and re-run 'openclaw gateway'"
  echo ""
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo "Installing ollama-memory-embeddings..."
echo ""
echo "This configures OpenClaw memory search to use Ollama as the embeddings"
echo "server (OpenAI-compatible /v1/embeddings). Chat routing is not affected."
echo ""

require_cmd node
require_cmd curl
require_cmd ollama

# openclaw CLI is optional (needed for restart only)
if ! command -v openclaw >/dev/null 2>&1; then
  echo "NOTE: 'openclaw' CLI not found. Gateway restart will be skipped."
  SKIP_RESTART=1
fi

validate_model "$MODEL"
validate_import_mode "$IMPORT_LOCAL_GGUF"
validate_reindex_mode "$REINDEX_MEMORY"

if ! ollama_running; then
  echo "ERROR: Ollama is not reachable at http://127.0.0.1:11434"
  echo "Start Ollama first, then re-run installer."
  exit 1
fi

prompt_model_if_needed
validate_model "$MODEL"

# ── GGUF detection and optional import ───────────────────────────────────────

LOCAL_GGUF=""
LOCAL_GGUF_MATCHES_MODEL=0
if LOCAL_GGUF="$(find_local_embedding_gguf)"; then
  echo "Detected local embedding GGUF:"
  echo "  $LOCAL_GGUF"
  if gguf_matches_selected_model "$LOCAL_GGUF" "$MODEL"; then
    LOCAL_GGUF_MATCHES_MODEL=1
  else
    DETECTED_GGUF_MODEL="$(guess_model_from_gguf "$LOCAL_GGUF")"
    echo "Local GGUF does not match selected model '${MODEL}' (detected: ${DETECTED_GGUF_MODEL}); skipping GGUF import prompt."
  fi
fi

MODEL_TO_USE="$MODEL"
WILL_IMPORT="no"

if [ -n "$LOCAL_GGUF" ] && [ "$LOCAL_GGUF_MATCHES_MODEL" -eq 1 ]; then
  case "$IMPORT_LOCAL_GGUF" in
    yes) WILL_IMPORT="yes" ;;
    no) WILL_IMPORT="no" ;;
    auto)
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        # In non-interactive mode, auto = no (safe default; use --import-local-gguf yes to opt in)
        WILL_IMPORT="no"
        echo "Non-interactive mode: skipping GGUF import (use --import-local-gguf yes to enable)."
      else
        printf "Import local GGUF into Ollama as '%s'? [Y/n]: " "$IMPORT_MODEL_NAME"
        read -r yn
        case "${yn:-Y}" in
          Y|y|yes|YES) WILL_IMPORT="yes" ;;
          *) WILL_IMPORT="no" ;;
        esac
      fi
      ;;
  esac
elif [ -n "$LOCAL_GGUF" ] && [ "$IMPORT_LOCAL_GGUF" = "yes" ]; then
  echo "WARNING: --import-local-gguf yes ignored because detected GGUF does not match selected model '${MODEL}'."
fi

if [ "$WILL_IMPORT" = "yes" ]; then
  echo "Importing local GGUF into Ollama as: ${IMPORT_MODEL_NAME}"
  if import_gguf_to_ollama "$LOCAL_GGUF" "$IMPORT_MODEL_NAME"; then
    MODEL_TO_USE="$IMPORT_MODEL_NAME"
    echo "Import succeeded."
  else
    echo "WARNING: import failed. Falling back to pulling '${MODEL}'."
  fi
fi

# ── Ensure model is available in Ollama ──────────────────────────────────────

if ! model_exists_in_ollama "$MODEL_TO_USE"; then
  echo "Pulling Ollama model: ${MODEL_TO_USE}"
  ollama pull "$MODEL_TO_USE"
fi

# Normalize for config and API calls
MODEL_TO_USE_CANON="$(normalize_model "$MODEL_TO_USE")"
echo "Using model: ${MODEL_TO_USE_CANON}"

# ── Install skill files ─────────────────────────────────────────────────────

echo ""
echo "1. Skill files -> ${SKILLS_DIR}/"
mkdir -p "$SKILLS_DIR"
for f in SKILL.md README.md install.sh verify.sh; do
  if [ -f "${SKILL_DIR}/${f}" ]; then
    # Avoid copying a file onto itself when running from installed skill path.
    if [ "${SKILL_DIR}/${f}" != "${SKILLS_DIR}/${f}" ]; then
      cp "${SKILL_DIR}/${f}" "${SKILLS_DIR}/"
    fi
  fi
done
for f in enforce.sh watchdog.sh; do
  if [ -f "${SKILL_DIR}/${f}" ]; then
    if [ "${SKILL_DIR}/${f}" != "${SKILLS_DIR}/${f}" ]; then
      cp "${SKILL_DIR}/${f}" "${SKILLS_DIR}/"
    fi
  fi
done
chmod +x "${SKILLS_DIR}/install.sh" "${SKILLS_DIR}/verify.sh" "${SKILLS_DIR}/enforce.sh" "${SKILLS_DIR}/watchdog.sh" 2>/dev/null || true

# ── Config backup ────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ -f "$CONFIG_PATH" ]; then
  BACKUP_PATH="${CONFIG_PATH}.bak.$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  cp "$CONFIG_PATH" "$BACKUP_PATH"
  echo "2. Config backup -> ${BACKUP_PATH}"
else
  echo "{}" > "$CONFIG_PATH"
  echo "2. Config created -> ${CONFIG_PATH}"
fi

# Capture pre-change embedding fingerprint to decide if reindex is needed.
PRE_MS="$(node -e '
const fs=require("fs");
const p=process.argv[1];
let cfg={};
try { cfg=JSON.parse(fs.readFileSync(p,"utf8")); } catch (_) {}
const ms=cfg?.agents?.defaults?.memorySearch || {};
const fp={
  provider: ms.provider || "",
  model: ms.model || "",
  baseUrl: ms?.remote?.baseUrl || "",
  apiKeySet: !!(ms?.remote?.apiKey || ""),
};
process.stdout.write(JSON.stringify(fp));
' "$CONFIG_PATH")"

# ── Enforce config (single source of truth) ───────────────────────────────────

"${SKILLS_DIR}/enforce.sh" \
  --model "${MODEL_TO_USE_CANON}" \
  --openclaw-config "${CONFIG_PATH}" \
  --base-url "http://127.0.0.1:11434/v1/" >/dev/null

# ── Post-write sanity check ─────────────────────────────────────────────────

echo "3. Config updated -> ${CONFIG_PATH}"
echo ""
echo "   Verifying config write..."
export CONFIG_PATH
SANITY="$(node -e '
const fs = require("fs");
const p = process.env.CONFIG_PATH;
try {
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  const ms = cfg?.agents?.defaults?.memorySearch || {};
  console.log("   provider:  " + (ms.provider || "(missing)"));
  console.log("   model:     " + (ms.model || "(missing)"));
  console.log("   baseUrl:   " + (ms?.remote?.baseUrl || "(missing)"));
  console.log("   apiKey:    " + (ms?.remote?.apiKey ? "(set)" : "(missing)"));
  if (ms.provider !== "openai") { console.log("   WARNING: provider is not openai"); process.exit(1); }
  if (!ms.model) { console.log("   WARNING: model is empty"); process.exit(1); }
  if (!ms?.remote?.baseUrl) { console.log("   WARNING: baseUrl is empty"); process.exit(1); }
} catch (e) {
  console.error("   ERROR: config is not valid JSON: " + e.message);
  process.exit(1);
}
')"
echo "$SANITY"

if [ "$INSTALL_WATCHDOG" -eq 1 ]; then
  echo ""
  echo "   Installing drift auto-heal watchdog..."
  if [ "$(uname)" = "Darwin" ]; then
    "${SKILLS_DIR}/watchdog.sh" \
      --install-launchd \
      --model "${MODEL_TO_USE_CANON}" \
      --openclaw-config "${CONFIG_PATH}" \
      --interval-sec "${WATCHDOG_INTERVAL}" >/dev/null
    echo "   Watchdog installed (launchd, ${WATCHDOG_INTERVAL}s interval)."
  else
    echo "   WARNING: --install-watchdog currently supports macOS launchd only."
    echo "   Run watchdog manually: ${SKILLS_DIR}/watchdog.sh --once --model ${MODEL_TO_USE_CANON}"
  fi
fi

# ── Gateway restart ──────────────────────────────────────────────────────────

if [ "$SKIP_RESTART" -eq 1 ]; then
  echo ""
  echo "4. Skipping gateway restart (--skip-restart)"
else
  echo ""
  echo "4. Restarting OpenClaw gateway..."
  restart_gateway || true
fi

# ── Verify embeddings endpoint ───────────────────────────────────────────────

echo ""
echo "5. Verifying Ollama embeddings endpoint..."
if "${SKILLS_DIR}/verify.sh" --model "$MODEL_TO_USE_CANON" --base-url "http://127.0.0.1:11434/v1/"; then
  echo "   Verification passed."
else
  echo "   WARNING: Verification failed. Check Ollama model and gateway logs."
fi

# ── Optional memory reindex ──────────────────────────────────────────────────

POST_MS="$(node -e '
const fs=require("fs");
const p=process.argv[1];
let cfg={};
try { cfg=JSON.parse(fs.readFileSync(p,"utf8")); } catch (_) {}
const ms=cfg?.agents?.defaults?.memorySearch || {};
const fp={
  provider: ms.provider || "",
  model: ms.model || "",
  baseUrl: ms?.remote?.baseUrl || "",
  apiKeySet: !!(ms?.remote?.apiKey || ""),
};
process.stdout.write(JSON.stringify(fp));
' "$CONFIG_PATH")"

NEEDS_REINDEX=1
if [ "$PRE_MS" = "$POST_MS" ]; then
  NEEDS_REINDEX=0
fi

RUN_REINDEX=0
case "$REINDEX_MEMORY" in
  yes) RUN_REINDEX=1 ;;
  no) RUN_REINDEX=0 ;;
  auto)
    if [ "$NEEDS_REINDEX" -eq 1 ]; then
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        RUN_REINDEX=1
      else
        echo ""
        echo "6. Embedding fingerprint changed."
        printf "   Rebuild memory index now (recommended)? [Y/n]: "
        read -r yn
        case "${yn:-Y}" in
          Y|y|yes|YES) RUN_REINDEX=1 ;;
          *) RUN_REINDEX=0 ;;
        esac
      fi
    else
      RUN_REINDEX=0
    fi
    ;;
esac

if [ "$NEEDS_REINDEX" -eq 0 ]; then
  echo ""
  echo "6. Memory reindex not needed (embedding fingerprint unchanged)."
elif [ "$RUN_REINDEX" -eq 1 ]; then
  echo ""
  echo "6. Rebuilding memory index..."
  if command -v openclaw >/dev/null 2>&1; then
    if openclaw memory index --force --verbose; then
      echo "   Memory reindex completed."
    else
      echo "   WARNING: Memory reindex failed. Run manually:"
      echo "     openclaw memory index --force --verbose"
    fi
  else
    echo "   WARNING: openclaw CLI not found; cannot run reindex automatically."
    echo "   Run manually on host with OpenClaw CLI:"
    echo "     openclaw memory index --force --verbose"
  fi
else
  echo ""
  echo "6. Skipping memory reindex."
  if [ "$NEEDS_REINDEX" -eq 1 ]; then
    echo "   Recommended command:"
    echo "     openclaw memory index --force --verbose"
  fi
fi

echo ""
echo "Done. OpenClaw memory embeddings now use Ollama."
echo ""
echo "  Model:   ${MODEL_TO_USE_CANON}"
echo "  Config:  ${CONFIG_PATH}"
echo "  Enforce: ${SKILLS_DIR}/enforce.sh"
echo "  Guard:   ${SKILLS_DIR}/watchdog.sh"
echo "  Verify:  ${SKILLS_DIR}/verify.sh"
echo ""
