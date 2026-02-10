#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
CONFIG_PATH="${TMP_DIR}/openclaw.json"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "${CONFIG_PATH}")"
# No drift: config already matches desired state
cat > "${CONFIG_PATH}" <<'EOF'
{
  "agents": {
    "defaults": {
      "memorySearch": {
        "provider": "openai",
        "model": "embeddinggemma:latest",
        "remote": {
          "baseUrl": "http://127.0.0.1:11434/v1/",
          "apiKey": "ollama"
        }
      }
    }
  }
}
EOF

OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" bash "${ROOT_DIR}/dist/audit.sh" > "${TMP_DIR}/out.json" 2>&1
exit_ok=$?
# Audit with no drift and all commands present should exit 0
if [ $exit_ok -ne 0 ]; then
  echo "audit exit code: $exit_ok (expected 0 when no drift)"
  cat "${TMP_DIR}/out.json"
  exit 1
fi

# Output must be valid JSON with schemaVersion
schema="$(node -e "
const fs = require('fs');
const j = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
if (j.schemaVersion !== '1.0.0') throw new Error('missing or wrong schemaVersion');
if (j.status !== 'ok' && j.status !== 'warn') throw new Error('unexpected status: ' + j.status);
if (!j.commands || !Array.isArray(j.commands.detected)) throw new Error('missing commands.detected');
if (j.drift && j.drift.detected && j.status !== 'warn') throw new Error('drift detected but status not warn');
process.exit(0);
" "${TMP_DIR}/out.json")"

# Text format (same temp config); write to file to avoid SIGPIPE when piping to grep
OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" AUDIT_OUTPUT=text bash "${ROOT_DIR}/dist/audit.sh" > "${TMP_DIR}/text.out" 2>&1
audit_exit=$?
[ "$audit_exit" -eq 0 ] || [ "$audit_exit" -eq 1 ] || (cat "${TMP_DIR}/text.out"; exit 1)
grep -q "Audit Status:" "${TMP_DIR}/text.out"

echo "smoke audit passed"
