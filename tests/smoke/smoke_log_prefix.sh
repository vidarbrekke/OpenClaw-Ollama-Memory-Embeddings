#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
CONFIG_PATH="${TMP_DIR}/openclaw.json"
OUT="${TMP_DIR}/out"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "${CONFIG_PATH}")"
echo '{}' > "${CONFIG_PATH}"

# Run enforce (which uses log_info/log_warn/log_err). Capture all output.
OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" \
  bash "${ROOT_DIR}/dist/enforce.sh" --model embeddinggemma 2>&1 | tee "${OUT}" || true

# Every line that looks like a log line must match [INFO], [WARN], or [ERROR] prefix.
# Ignore empty lines and lines that are clearly not from our logger (e.g. usage).
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if [[ "$line" == "[INFO]"* ]] || [[ "$line" == "[WARN]"* ]] || [[ "$line" == "[ERROR]"* ]]; then
    continue
  fi
  # Allow lines that are not our log format (e.g. "Config: ..." from legacy log call)
  if [[ "$line" == "Config:"* ]] || [[ "$line" == "Backup:"* ]] || [[ "$line" == "provider="* ]] || [[ "$line" == "model="* ]] || [[ "$line" == "baseUrl="* ]] || [[ "$line" == "apiKey="* ]] || [[ "$line" == "legacy"* ]] || [[ "$line" == "No changes"* ]] || [[ "$line" == "Drift healed"* ]]; then
    continue
  fi
  # Strict: if we see a line that looks like a message but has no valid prefix, fail.
  if [[ "$line" == *"["* ]]; then
    echo "Unexpected log-like line without [INFO]/[WARN]/[ERROR]: $line"
    exit 1
  fi
done < "${OUT}"

echo "smoke log prefix passed"
