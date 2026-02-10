#!/usr/bin/env bash
# Drift watchdog for OpenClaw memorySearch embeddings config.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SH="${SKILL_DIR}/enforce.sh"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${HOME}/.openclaw/openclaw.json}"
MODEL=""
BASE_URL="http://127.0.0.1:11434/v1/"
INTERVAL_SEC=60
ONCE=0
RESTART_ON_HEAL=0
INSTALL_LAUNCHD=0
UNINSTALL_LAUNCHD=0
QUIET=0

PLIST_NAME="bot.molt.openclaw.embedding-guard"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG_DIR="${HOME}/.openclaw/logs"
STDOUT_LOG="${LOG_DIR}/embedding-guard.out.log"
STDERR_LOG="${LOG_DIR}/embedding-guard.err.log"

usage() {
  cat <<'EOF'
Usage:
  watchdog.sh [options]

Modes:
  --once                  run one check/heal cycle, then exit
  (default)               run continuously and check every --interval-sec
  --install-launchd       install + load launchd job (macOS)
  --uninstall-launchd     unload + remove launchd job (macOS)

Other OS guidance:
  Linux: run --once via cron/systemd timer
  Windows: not supported (bash script)

Linux cron example (every 5 min):
  */5 * * * * /bin/bash ~/.openclaw/skills/ollama-memory-embeddings/watchdog.sh --once --model embeddinggemma >/dev/null 2>&1

Options:
  --model <id>              model to enforce (required for new installs)
  --base-url <url>          base URL to enforce (default: http://127.0.0.1:11434/v1/)
  --openclaw-config <path>  config path (default: ~/.openclaw/openclaw.json)
  --interval-sec <n>        check interval (default: 60)
  --restart-on-heal         restart gateway after drift heal
  --quiet                   suppress non-error output
  --help                    show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --openclaw-config) CONFIG_PATH="$2"; shift 2 ;;
    --interval-sec) INTERVAL_SEC="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --restart-on-heal) RESTART_ON_HEAL=1; shift ;;
    --install-launchd) INSTALL_LAUNCHD=1; shift ;;
    --uninstall-launchd) UNINSTALL_LAUNCHD=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

log() {
  [ "$QUIET" -eq 1 ] || echo "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found in PATH."
    exit 1
  }
}

resolve_model_if_missing() {
  if [ -n "$MODEL" ]; then
    return 0
  fi
  MODEL="$(node -e '
const fs=require("fs");
const p=process.argv[1];
try {
  const cfg=JSON.parse(fs.readFileSync(p,"utf8"));
  process.stdout.write(cfg?.agents?.defaults?.memorySearch?.model || "");
} catch (_) {}
' "$CONFIG_PATH")"
  if [ -z "$MODEL" ]; then
    echo "ERROR: --model is required (or set memorySearch.model first)."
    exit 1
  fi
}

run_cycle() {
  set +e
  "$ENFORCE_SH" \
    --check-only \
    --model "$MODEL" \
    --base-url "$BASE_URL" \
    --openclaw-config "$CONFIG_PATH" \
    --quiet
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] OK: no drift"
    return 0
  fi
  if [ "$status" -ne 10 ]; then
    log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: drift check failed (status $status)"
    return 1
  fi

  log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRIFT: healing..."
  if [ "$RESTART_ON_HEAL" -eq 1 ]; then
    "$ENFORCE_SH" --model "$MODEL" --base-url "$BASE_URL" --openclaw-config "$CONFIG_PATH" --restart-on-change --quiet
  else
    "$ENFORCE_SH" --model "$MODEL" --base-url "$BASE_URL" --openclaw-config "$CONFIG_PATH" --quiet
  fi
  log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] HEALED"
}

install_launchd() {
  if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: --install-launchd is macOS only."
    echo "Linux recommendation:"
    echo "  Use cron or a systemd timer to run:"
    echo "  /bin/bash ${SKILL_DIR}/watchdog.sh --once --model <model>"
    echo "Windows: not supported (bash script)."
    exit 1
  fi
  require_cmd launchctl
  require_cmd node
  resolve_model_if_missing
  mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
  local shell_bin
  shell_bin="$(command -v bash)"
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${shell_bin}</string>
    <string>${SKILL_DIR}/watchdog.sh</string>
    <string>--once</string>
    <string>--model</string>
    <string>${MODEL}</string>
    <string>--base-url</string>
    <string>${BASE_URL}</string>
    <string>--openclaw-config</string>
    <string>${CONFIG_PATH}</string>
$( [ "$RESTART_ON_HEAL" -eq 1 ] && echo "    <string>--restart-on-heal</string>" )
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${INTERVAL_SEC}</integer>
  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl kickstart -k "gui/$(id -u)/${PLIST_NAME}"
  log "Installed launchd watchdog: ${PLIST_PATH}"
}

uninstall_launchd() {
  if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: --uninstall-launchd is macOS only."
    echo "Windows: not supported (bash script)."
    exit 1
  fi
  require_cmd launchctl
  launchctl bootout "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  log "Removed launchd watchdog: ${PLIST_PATH}"
}

if [ "$INSTALL_LAUNCHD" -eq 1 ] && [ "$UNINSTALL_LAUNCHD" -eq 1 ]; then
  echo "ERROR: choose only one of --install-launchd or --uninstall-launchd."
  exit 1
fi

if [ "$INSTALL_LAUNCHD" -eq 1 ]; then
  install_launchd
  exit 0
fi

if [ "$UNINSTALL_LAUNCHD" -eq 1 ]; then
  uninstall_launchd
  exit 0
fi

require_cmd node
resolve_model_if_missing

if [ "$ONCE" -eq 1 ]; then
  run_cycle
  exit 0
fi

while true; do
  run_cycle || true
  sleep "$INTERVAL_SEC"
done
