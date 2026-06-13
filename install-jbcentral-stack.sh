#!/bin/bash
# install-jbcentral-stack.sh
#
# Installs the pino + headroom + jbcentral proxy stack for Claude Code.
# Idempotent — safe to re-run for updates.
#
# Requirements:
#   - node >= 20
#   - jbcentral (JetBrains Central CLI)
#   - git
#   - Python 3.11, 3.12 or 3.13  (not 3.14+: headroom's Rust extensions not yet ported)
#
# Usage:
#   bash install-jbcentral-stack.sh
#   bash install-jbcentral-stack.sh --pino-dir ~/tools/pino
#   bash install-jbcentral-stack.sh --test        # dry run in /tmp, auto-restores ~/.claude/settings.json
set -euo pipefail

# ── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}▸${NC} $*"; }

# ── defaults ───────────────────────────────────────────────────────────────
PINO_DIR="${PINO_DIR:-$HOME/JetBrains/pino}"
VENV_DIR="${VENV_DIR:-$HOME/.venv-headroom}"
PINO_REPO="https://github.com/hybloid/pino.git"
PINO_BRANCH="feat/subagent-5m-ttl"
# Install headroom from our fork (carries the Claude Code session-id cache key fix).
# Override: HEADROOM_PKG='headroom-ai[all]' to use upstream PyPI instead.
HEADROOM_PKG="${HEADROOM_PKG:-headroom-ai[all] @ git+https://github.com/hybloid/headroom@release/v0.25.0-session-id-fix}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
MODE_FILE="$HOME/.claude/proxy-mode"

TEST_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pino-dir)  PINO_DIR="$2";  shift 2 ;;
    --venv-dir)  VENV_DIR="$2";  shift 2 ;;
    --test)      TEST_MODE=1;    shift   ;;
    *) err "Unknown argument: $1" ;;
  esac
done

# ── test mode: temp dirs + settings.json backup/restore ────────────────────
if [[ "$TEST_MODE" -eq 1 ]]; then
  PINO_DIR="/tmp/pino-test"
  VENV_DIR="/tmp/venv-headroom-test"
  SETTINGS_BAK="${CLAUDE_SETTINGS}.test-bak"
  cp "$CLAUDE_SETTINGS" "$SETTINGS_BAK" 2>/dev/null || true
  trap '
    echo ""
    echo -e "\033[1;33m! test cleanup\033[0m"
    rm -rf /tmp/pino-test /tmp/venv-headroom-test
    if [[ -f "'"$SETTINGS_BAK"'" ]]; then
      cp "'"$SETTINGS_BAK"'" "'"$CLAUDE_SETTINGS"'"
      rm -f "'"$SETTINGS_BAK"'"
      echo -e "\033[0;32m✓\033[0m settings.json restored"
    fi
  ' EXIT
  echo -e "\n\033[1;33m  TEST MODE — install to /tmp, settings.json will be restored on exit\033[0m"
fi

echo ""
echo "  pino + headroom + jbcentral stack installer"
echo "  pino dir  : $PINO_DIR  ($PINO_BRANCH)"
echo "  venv dir  : $VENV_DIR"
echo ""

# ── 1. Prerequisites ────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v node >/dev/null 2>&1 || err "node not found — install via: brew install node"
command -v git  >/dev/null 2>&1 || err "git not found"
command -v nc   >/dev/null 2>&1 || err "nc (netcat) not found"

NODE_VER=$(node --version | tr -d 'v')
NODE_MAJOR="${NODE_VER%%.*}"
[[ "$NODE_MAJOR" -ge 20 ]] || err "node >= 20 required (got $NODE_VER)"

if ! command -v jbcentral >/dev/null 2>&1; then
  err "jbcentral not found — download JetBrains Central CLI from https://jb.gg/jbcentral"
fi

ok "node v$NODE_VER   git OK   jbcentral OK"

# ── 2. Find Python 3.11–3.13 ───────────────────────────────────────────────
step "Finding Python 3.11–3.13"

PYTHON=""
for v in python3.13 python3.12 python3.11; do
  if command -v "$v" >/dev/null 2>&1; then
    PYTHON="$v"; break
  fi
done

[[ -n "$PYTHON" ]] || \
  err "No Python 3.11–3.13 found. Install via: brew install python@3.11\n  (Python 3.14+ not yet supported by headroom's Rust extensions)"

ok "Using $PYTHON ($($PYTHON --version))"

# ── 3. Clone / update pino (our fork) ──────────────────────────────────────
step "Setting up pino  →  $PINO_REPO  ($PINO_BRANCH)"

if [[ -d "$PINO_DIR/.git" ]]; then
  CURRENT_REMOTE=$(git -C "$PINO_DIR" remote get-url origin 2>/dev/null || echo "")
  if [[ "$CURRENT_REMOTE" != "$PINO_REPO" ]]; then
    warn "Existing clone points to $CURRENT_REMOTE — updating remote to our fork"
    git -C "$PINO_DIR" remote set-url origin "$PINO_REPO"
  fi
  git -C "$PINO_DIR" fetch -q origin
  git -C "$PINO_DIR" checkout -q "$PINO_BRANCH" 2>/dev/null || \
    git -C "$PINO_DIR" checkout -q -b "$PINO_BRANCH" "origin/$PINO_BRANCH"
  git -C "$PINO_DIR" pull -q --rebase 2>/dev/null && ok "pino updated" || \
    warn "pino pull failed, continuing with existing version"
else
  mkdir -p "$(dirname "$PINO_DIR")"
  git clone -q -b "$PINO_BRANCH" "$PINO_REPO" "$PINO_DIR"
  ok "pino cloned → $PINO_DIR"
fi

# ── 4. Install npm deps ─────────────────────────────────────────────────────
step "Installing pino npm dependencies"

if [[ -d "$PINO_DIR/node_modules" ]]; then
  ok "node_modules already present — skipping"
else
  (cd "$PINO_DIR" && npm install -q)
  ok "npm install done"
fi

# ── 5. Install headroom (our fork) ─────────────────────────────────────────
step "Installing headroom  →  $VENV_DIR"

if [[ -x "$VENV_DIR/bin/headroom" ]]; then
  HEADROOM_VER=$("$VENV_DIR/bin/headroom" --version 2>/dev/null | awk '{print $NF}')
  ok "headroom already installed ($HEADROOM_VER) — skipping  (re-run with HEADROOM_PKG='' to force reinstall)"
else
  echo "  Installing headroom (builds Rust core — may take a few minutes)..."
  "$PYTHON" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet "$HEADROOM_PKG"
  HEADROOM_VER=$("$VENV_DIR/bin/headroom" --version 2>/dev/null | awk '{print $NF}')
  ok "headroom $HEADROOM_VER installed"
fi

# ── 6. Ensure launcher is executable ───────────────────────────────────────
step "Configuring launcher"

LAUNCHER="$PINO_DIR/start-with-jbcentral.sh"

[[ -f "$LAUNCHER" ]] || err "Launcher not found at $LAUNCHER — git clone may have failed"
chmod +x "$LAUNCHER"
ok "launcher ready → $LAUNCHER"

# ── 7. Update ~/.claude/settings.json ──────────────────────────────────────
step "Updating Claude Code settings"

mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
[[ -f "$CLAUDE_SETTINGS" ]] || echo '{}' > "$CLAUDE_SETTINGS"

python3 - "$CLAUDE_SETTINGS" "$LAUNCHER" <<'PYEOF'
import json, sys

path, launcher = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

changed = []

if cfg.get("apiKeyHelper") != launcher:
    cfg["apiKeyHelper"] = launcher
    changed.append("apiKeyHelper")

env = cfg.setdefault("env", {})
if env.get("ANTHROPIC_BASE_URL") != "http://127.0.0.1:8787":
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8787"
    changed.append("ANTHROPIC_BASE_URL")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("updated: " + ", ".join(changed) if changed else "already up to date")
PYEOF

ok "settings.json configured"

# ── 8. Set default proxy mode ───────────────────────────────────────────────
step "Setting default proxy mode"

if [[ -f "$MODE_FILE" ]]; then
  ok "proxy-mode already set: $(cat "$MODE_FILE")"
else
  echo "headroom+pino" > "$MODE_FILE"
  ok "proxy-mode set to: headroom+pino"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo ""
echo "  Current mode : $(cat "$MODE_FILE")"
echo "  Launcher     : $LAUNCHER"
echo ""
echo "  Switch mode:"
echo "    echo \"pino\"          > ~/.claude/proxy-mode   # cache injection only"
echo "    echo \"headroom\"      > ~/.claude/proxy-mode   # context compression only"
echo "    echo \"headroom+pino\" > ~/.claude/proxy-mode   # compression + cache (recommended)"
echo ""
echo "  Stats (when headroom is running):"
echo "    curl -s http://127.0.0.1:8787/stats | python3 -m json.tool"
echo ""
echo "  Logs:"
echo "    tail -f /tmp/pino-8787.log"
echo "    tail -f /tmp/headroom-8787.log"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
