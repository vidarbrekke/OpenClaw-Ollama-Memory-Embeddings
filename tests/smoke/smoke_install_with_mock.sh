#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
MOCK_PORT="${MOCK_OLLAMA_PORT:-11434}"
MOCK_MODEL="${MOCK_OLLAMA_MODEL:-embeddinggemma:latest}"
MOCK_PID=""

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "${MOCK_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    cat <<'OUT'
NAME ID SIZE MODIFIED
embeddinggemma:latest abc 1 GB now
OUT
    ;;
  pull)
    exit 0
    ;;
  create)
    exit 0
    ;;
  *)
    echo "unsupported mock ollama subcommand: ${cmd}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${TMP_DIR}/bin/ollama"

export PATH="${TMP_DIR}/bin:${PATH}"
export HOME="${TMP_DIR}/home"
mkdir -p "${HOME}"
export OPENCLAW_CONFIG_PATH="${HOME}/.openclaw/openclaw.json"

MOCK_OLLAMA_PORT="${MOCK_PORT}" MOCK_OLLAMA_MODEL="${MOCK_MODEL}" \
  node "${ROOT_DIR}/tests/smoke/mock_ollama_server.js" >"${TMP_DIR}/mock.log" 2>&1 &
MOCK_PID="$!"

# wait until server is reachable
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${MOCK_PORT}/api/tags" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! curl -fsS "http://127.0.0.1:${MOCK_PORT}/api/tags" >/dev/null 2>&1; then
  echo "mock ollama server did not start"
  exit 1
fi

bash "${ROOT_DIR}/dist/install.sh" \
  --non-interactive \
  --model embeddinggemma \
  --skip-restart \
  --reindex-memory no

node -e '
const fs = require("fs");
const p = process.env.OPENCLAW_CONFIG_PATH;
const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
const ms = cfg?.agents?.defaults?.memorySearch || {};
if (ms.provider !== "openai") process.exit(1);
if (ms.model !== "embeddinggemma:latest") process.exit(1);
if ((ms?.remote?.baseUrl || "") !== "http://127.0.0.1:11434/v1/") process.exit(1);
if (!(ms?.remote?.apiKey || "")) process.exit(1);
'

echo "smoke install passed"
