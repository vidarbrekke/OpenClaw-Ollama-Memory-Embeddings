#!/usr/bin/env bash
# Verify Ollama embeddings endpoint with selected model.
# Checks: model exists in Ollama → endpoint reachable → valid embedding response.
set -euo pipefail

MODEL=""
BASE_URL=""
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${HOME}/.openclaw/openclaw.json}"
VERBOSE=0

usage() {
  cat <<'EOF'
Usage:
  verify.sh [--model <id>] [--base-url <url>] [--openclaw-config <path>] [--verbose]

Verifies that the configured Ollama embeddings endpoint is working correctly.

Behavior:
  - If --model is omitted, reads memorySearch.model from OpenClaw config.
  - If --base-url is omitted, reads memorySearch.remote.baseUrl from config,
    then defaults to http://127.0.0.1:11434/v1/
  - Checks: (1) model exists in Ollama, (2) endpoint returns valid embedding.
  - Use --verbose to dump raw API response on failure.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --openclaw-config) CONFIG_PATH="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found in PATH."
    exit 1
  }
}

# Normalize model name: add :latest if no tag present.
normalize_model() {
  local m="$1"
  if [[ "$m" != *:* ]]; then
    echo "${m}:latest"
  else
    echo "$m"
  fi
}

require_cmd node
require_cmd curl

# ── Read config if needed ────────────────────────────────────────────────────

if [ -z "$MODEL" ] || [ -z "$BASE_URL" ]; then
  export CONFIG_PATH
  MAP_OUTPUT="$(node -e '
const fs = require("fs");
const p = process.env.CONFIG_PATH;
const CANDIDATES = [
  ["agents","defaults","memorySearch"],
  ["memorySearch"],
  ["agents","memorySearch"],
  ["agents","defaults","memory","search"],
  ["memory","search"],
];
function getAt(obj, path) {
  let cur = obj;
  for (const k of path) {
    if (!cur || typeof cur !== "object" || !(k in cur)) return undefined;
    cur = cur[k];
  }
  return cur;
}
function resolveMs(cfg) {
  const canonical = getAt(cfg, CANDIDATES[0]);
  if (canonical && typeof canonical === "object" && !Array.isArray(canonical)) return canonical;
  for (const p of CANDIDATES.slice(1)) {
    const v = getAt(cfg, p);
    if (v && typeof v === "object" && !Array.isArray(v)) return v;
  }
  return {};
}
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch (_) {}
const ms = resolveMs(cfg);
const model = ms.model || "";
const base = (ms?.remote?.baseUrl || "http://127.0.0.1:11434/v1/").trim();
console.log(model);
console.log(base);
')"
  CFG_MODEL="$(printf "%s\n" "$MAP_OUTPUT" | sed -n '1p')"
  CFG_BASE_URL="$(printf "%s\n" "$MAP_OUTPUT" | sed -n '2p')"
  [ -z "$MODEL" ] && MODEL="$CFG_MODEL"
  [ -z "$BASE_URL" ] && BASE_URL="$CFG_BASE_URL"
fi

if [ -z "$MODEL" ]; then
  echo "ERROR: Could not determine embedding model."
  echo "  Provide --model <id> or configure memorySearch.model in ${CONFIG_PATH}"
  exit 1
fi

# Normalize model tag
MODEL="$(normalize_model "$MODEL")"

# Normalize URL to .../v1 and call /embeddings
BASE_URL="${BASE_URL%/}"
if [[ "$BASE_URL" != */v1 ]]; then
  BASE_URL="${BASE_URL}/v1"
fi
EMBED_URL="${BASE_URL}/embeddings"

echo "Checking Ollama embeddings:"
echo "  URL:   ${EMBED_URL}"
echo "  Model: ${MODEL}"

# ── Step 1: Check model exists in Ollama ─────────────────────────────────────

echo ""
echo "  [1/2] Checking model availability in Ollama..."
if command -v ollama >/dev/null 2>&1; then
  if ! ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qE "^(${MODEL}|${MODEL%%:*})$" 2>/dev/null; then
    echo "  WARNING: model '${MODEL}' not found in 'ollama list'."
    echo "  The model may not be pulled. Try: ollama pull ${MODEL%%:*}"
    echo ""
    echo "  Continuing with endpoint check anyway..."
  else
    echo "  Model '${MODEL}' found in Ollama."
  fi
else
  echo "  NOTE: 'ollama' CLI not in PATH; skipping model existence check."
fi

# ── Step 2: Call embeddings endpoint ─────────────────────────────────────────

echo "  [2/2] Calling embeddings endpoint..."

PAYLOAD=$(cat <<EOF
{"model":"${MODEL}","input":"openclaw memory embeddings health check"}
EOF
)

HTTP_CODE=""
RESP=""

# Capture HTTP status and response body without mixing stderr into status code.
TMP_BODY="$(mktemp)"
TMP_ERR="$(mktemp)"
set +e
HTTP_CODE="$(curl -sS -o "$TMP_BODY" -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$EMBED_URL" 2>"$TMP_ERR")"
CURL_STATUS=$?
set -e

RESP="$(cat "$TMP_BODY")"
CURL_ERR="$(cat "$TMP_ERR")"
rm -f "$TMP_BODY" "$TMP_ERR"

if [ "$CURL_STATUS" -ne 0 ]; then
  echo "  ERROR: curl failed to reach ${EMBED_URL}"
  echo "  Is Ollama running? Check: curl http://127.0.0.1:11434/api/tags"
  if [ "$VERBOSE" -eq 1 ] && [ -n "$CURL_ERR" ]; then
    echo "  curl error: ${CURL_ERR}"
  fi
  exit 1
fi

if [ "$HTTP_CODE" != "200" ]; then
  echo "  ERROR: embeddings endpoint returned HTTP ${HTTP_CODE}"
  if [ "$VERBOSE" -eq 1 ] && [ -n "$RESP" ]; then
    echo ""
    echo "  Raw response (first 2000 chars):"
    echo "  ${RESP:0:2000}"
  fi
  # Try to extract error message
  if [ -n "$RESP" ]; then
    ERR_MSG="$(echo "$RESP" | node -e '
      let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
        try { const j=JSON.parse(d); console.log(j.error||j.message||""); } catch { console.log(""); }
      });
    ' 2>/dev/null)" || true
    if [ -n "$ERR_MSG" ]; then
      echo "  Server error: ${ERR_MSG}"
    fi
  fi
  exit 1
fi

export RESP VERBOSE
node <<'NODEOF'
const raw = process.env.RESP || "";
const verbose = process.env.VERBOSE === "1";
let body;
try { body = JSON.parse(raw); } catch {
  console.error("  ERROR: embeddings endpoint did not return valid JSON.");
  if (verbose) {
    console.error("  Raw response (first 2000 chars):");
    console.error("  " + raw.slice(0, 2000));
  }
  process.exit(1);
}

const arr = body?.data?.[0]?.embedding;
if (!Array.isArray(arr) || arr.length === 0) {
  console.error("  ERROR: embeddings response missing data[0].embedding.");
  console.error("  Top-level keys: " + Object.keys(body).join(", "));
  if (verbose) {
    console.error("  Raw response (first 2000 chars):");
    console.error("  " + raw.slice(0, 2000));
  }
  process.exit(1);
}
console.log(`  OK: received embedding vector (dims=${arr.length})`);
NODEOF
