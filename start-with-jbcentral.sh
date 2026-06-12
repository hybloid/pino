#!/bin/bash
# Proxy launcher for Claude Code → jbcentral.
#
# MODE (читается из ~/.claude/proxy-mode или PROXY_MODE env):
#   pino          — только pino     (cache injection)              :8787 → jbcentral
#   headroom      — только headroom (context compression)          :8787 → jbcentral
#   headroom+pino — оба             (headroom сжимает, pino кешит) :8787 → :8788 → jbcentral
#
# ANTHROPIC_BASE_URL всегда http://127.0.0.1:8787
#
# Поменять режим: echo "headroom+pino" > ~/.claude/proxy-mode
set -euo pipefail

PINO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY_PORT=8787
SECONDARY_PORT=8788
HEADROOM_BIN="/Users/d.kopfmann/.venv-headroom/bin/headroom"

MODE_FILE="$HOME/.claude/proxy-mode"
MODE="${PROXY_MODE:-$(cat "$MODE_FILE" 2>/dev/null || echo "pino")}"

KEY=$(jbcentral proxy start --ensure-updated --return-key)
JBC_URL="http://127.0.0.1:19516/wire/$KEY/claude-code/anthropic"

port_up() { nc -z 127.0.0.1 "$1" 2>/dev/null; }

wait_port() {
  local port="$1" tries="${2:-30}" interval="${3:-0.2}"
  for _ in $(seq 1 "$tries"); do port_up "$port" && return 0; sleep "$interval"; done
  return 1
}

kill_pid_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local pid; pid=$(cat "$f")
  kill "$pid" 2>/dev/null || true
  rm -f "$f"
}

start_pino() {
  local upstream="$1" port="$2"
  local pid_file="/tmp/pino-${port}.pid"
  local ups_file="/tmp/pino-${port}.upstream"

  if [[ -f "$pid_file" ]]; then
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null && [[ "$(cat "$ups_file" 2>/dev/null)" == "$upstream" ]]; then
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    sleep 0.2
  fi

  PORT="$port" AUTO_CACHE=1 \
    UPSTREAM_URL="$upstream" \
    TRANSFORM_FILE="$PINO_DIR/src/transforms/default.js" \
    node "$PINO_DIR/bin/pino-proxy.js" >> "/tmp/pino-${port}.log" 2>&1 &

  echo $! > "$pid_file"
  echo "$upstream" > "$ups_file"
  wait_port "$port" || { echo "pino failed to start on :$port" >&2; exit 1; }
}

start_headroom() {
  local upstream="$1" port="$2"
  local pid_file="/tmp/headroom-${port}.pid"
  local ups_file="/tmp/headroom-${port}.upstream"

  if [[ ! -x "$HEADROOM_BIN" ]]; then
    echo "headroom not found at $HEADROOM_BIN" >&2
    echo "Run the installer again or: $PYTHON -m venv /Users/d.kopfmann/.venv-headroom && /Users/d.kopfmann/.venv-headroom/bin/pip install 'headroom-ai[all]'" >&2
    exit 1
  fi

  if [[ -f "$pid_file" ]]; then
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null && [[ "$(cat "$ups_file" 2>/dev/null)" == "$upstream" ]]; then
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    sleep 0.5
  fi

  "$HEADROOM_BIN" proxy --port "$port" --anthropic-api-url "$upstream" \
    >> "/tmp/headroom-${port}.log" 2>&1 &

  echo $! > "$pid_file"
  echo "$upstream" > "$ups_file"
  wait_port "$port" 60 0.5 || { echo "headroom failed to start on :$port" >&2; exit 1; }
}

case "$MODE" in
  pino)
    kill_pid_file "/tmp/headroom-${ENTRY_PORT}.pid"
    kill_pid_file "/tmp/pino-${SECONDARY_PORT}.pid"
    start_pino "$JBC_URL" "$ENTRY_PORT"
    ;;
  headroom)
    kill_pid_file "/tmp/pino-${ENTRY_PORT}.pid"
    kill_pid_file "/tmp/pino-${SECONDARY_PORT}.pid"
    start_headroom "$JBC_URL" "$ENTRY_PORT"
    ;;
  headroom+pino)
    # правильный порядок: headroom сжимает, pino добавляет 1h кеш
    kill_pid_file "/tmp/pino-${ENTRY_PORT}.pid"
    start_pino "$JBC_URL" "$SECONDARY_PORT"
    start_headroom "http://127.0.0.1:$SECONDARY_PORT" "$ENTRY_PORT"
    ;;
  *)
    echo "Unknown mode: '$MODE' — valid: pino | headroom | headroom+pino" >&2
    exit 1
    ;;
esac

echo "$KEY"
