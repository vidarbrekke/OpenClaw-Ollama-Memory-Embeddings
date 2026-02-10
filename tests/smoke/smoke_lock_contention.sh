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
echo "{}" > "${CONFIG_PATH}"

# Stale lock recovery: create stale lock dir with dead pid and old timestamp.
LOCK_DIR="${CONFIG_PATH}.lock"
mkdir -p "${LOCK_DIR}"
cat > "${LOCK_DIR}/meta" <<EOF
pid=999999
started_epoch=1
started_utc=1970-01-01T00:00:01Z
host=stale-test
EOF

OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" \
OPENCLAW_LOCK_TIMEOUT_SEC=5 \
OPENCLAW_LOCK_STALE_SEC=1 \
  bash "${ROOT_DIR}/dist/enforce.sh" --model embeddinggemma --quiet

# Lock contention: create a lock that should not be considered stale.
mkdir -p "${LOCK_DIR}"
cat > "${LOCK_DIR}/meta" <<EOF
pid=$$
started_epoch=$(date +%s)
started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host=contention-test
EOF

set +e
OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" \
OPENCLAW_LOCK_TIMEOUT_SEC=1 \
OPENCLAW_LOCK_STALE_SEC=600 \
  bash "${ROOT_DIR}/dist/enforce.sh" --model embeddinggemma --quiet >/dev/null 2>&1
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "expected lock contention to fail, but it succeeded"
  exit 1
fi

rm -rf "${LOCK_DIR}"

echo "smoke lock contention passed"
