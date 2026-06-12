#!/bin/bash
# install-jbcentral-stack.sh
#
# Устанавливает стек: pino + headroom + jbcentral для Claude Code.
# Идемпотентный — безопасно запускать повторно при обновлении.
#
# Требования:
#   - node >= 20
#   - jbcentral (JetBrains Central CLI)
#   - git
#   - Python 3.11, 3.12 или 3.13 (не 3.14+, PyO3 пока не поддерживает)
#
# Использование:
#   bash install-jbcentral-stack.sh
#   bash install-jbcentral-stack.sh --pino-dir ~/tools/pino   # кастомный путь
set -euo pipefail

# ── цвета ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}▸${NC} $*"; }

# ── аргументы ──────────────────────────────────────────────────────────────
PINO_DIR="${PINO_DIR:-$HOME/JetBrains/pino}"
VENV_DIR="$HOME/.venv-headroom"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
MODE_FILE="$HOME/.claude/proxy-mode"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pino-dir) PINO_DIR="$2"; shift 2 ;;
    --venv-dir) VENV_DIR="$2"; shift 2 ;;
    *) err "Unknown arg: $1" ;;
  esac
done

echo ""
echo "  pino-proxy + headroom + jbcentral stack installer"
echo "  pino dir : $PINO_DIR"
echo "  venv dir : $VENV_DIR"
echo ""

# ── 1. Prerequisites ────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v node  >/dev/null 2>&1 || err "node not found — install via: brew install node"
command -v git   >/dev/null 2>&1 || err "git not found"
command -v nc    >/dev/null 2>&1 || err "nc (netcat) not found"

NODE_VER=$(node --version | tr -d 'v')
NODE_MAJOR="${NODE_VER%%.*}"
[[ "$NODE_MAJOR" -ge 20 ]] || err "node >= 20 required (got $NODE_VER)"

if ! command -v jbcentral >/dev/null 2>&1; then
  err "jbcentral not found — download JetBrains Central CLI from https://jb.gg/jbcentral"
fi

ok "node v$NODE_VER  git OK  jbcentral OK"

# ── 2. Найти Python 3.11–3.13 ───────────────────────────────────────────────
step "Finding Python 3.11–3.13"

PYTHON=""
for v in python3.13 python3.12 python3.11; do
  if command -v "$v" >/dev/null 2>&1; then
    PYTHON="$v"; break
  fi
done

if [[ -z "$PYTHON" ]]; then
  err "No Python 3.11–3.13 found. Install via: brew install python@3.11\n  (Python 3.14+ not supported by headroom's Rust extensions yet)"
fi
ok "Using $PYTHON ($($PYTHON --version))"

# ── 3. Clone / update pino ──────────────────────────────────────────────────
step "Setting up pino"

if [[ -d "$PINO_DIR/.git" ]]; then
  git -C "$PINO_DIR" pull --rebase -q 2>/dev/null && ok "pino updated" || warn "pino pull failed, continuing with existing version"
else
  mkdir -p "$(dirname "$PINO_DIR")"
  git clone -q https://github.com/alxsuv/pino "$PINO_DIR"
  ok "pino cloned → $PINO_DIR"
fi

# ── 4. Patch pino: UPSTREAM_URL support ─────────────────────────────────────
step "Patching pino (UPSTREAM_URL support)"

# config.js — добавляем parseUpstream() если ещё нет
if grep -q "parseUpstream" "$PINO_DIR/src/config.js" 2>/dev/null; then
  ok "config.js patch already applied"
else
  python3 - "$PINO_DIR/src/config.js" <<'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

patch = '''
export function parseUpstream() {
  const raw = process.env.UPSTREAM_URL;
  if (!raw) return { protocol: "https:", hostname: UPSTREAM_HOST, port: 443, basePath: "" };
  const u = new URL(raw);
  return {
    protocol: u.protocol,
    hostname: u.hostname,
    port: u.port ? Number(u.port) : u.protocol === "https:" ? 443 : 80,
    basePath: u.pathname.replace(/\\/$/, ""),
  };
}'''

text = text.replace(
  'export const UPSTREAM_HOST = "api.anthropic.com";',
  'export const UPSTREAM_HOST = "api.anthropic.com";\n' + patch
)
open(path, 'w').write(text)
print("patched")
PYEOF
  ok "config.js patched"
fi

# server.js — используем parseUpstream вместо хардкода
if grep -q "parseUpstream" "$PINO_DIR/src/server.js" 2>/dev/null; then
  ok "server.js patch already applied"
else
  python3 - "$PINO_DIR/src/server.js" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

text = text.replace(
  'import { loadConfig, loadTransform, UPSTREAM_HOST } from "./config.js";',
  'import { loadConfig, loadTransform, UPSTREAM_HOST, parseUpstream } from "./config.js";'
)

text = text.replace(
  'export function createServer({ config, transformFn }) {\n  const { AUTO_CACHE, LOG_BODIES, LOG_DIR, TAIL_TTL, MODEL_OVERRIDE } = config;',
  'export function createServer({ config, transformFn }) {\n  const { AUTO_CACHE, LOG_BODIES, LOG_DIR, TAIL_TTL, MODEL_OVERRIDE } = config;\n  const upstream = parseUpstream();\n  const requestFn = upstream.protocol === "https:" ? https.request : http.request;'
)

text = text.replace('      headers.host = UPSTREAM_HOST;', '      headers.host = upstream.hostname;')

text = text.replace(
  '      const upReq = https.request(\n        {\n          hostname: UPSTREAM_HOST,\n          port: 443,\n          path: req.url,',
  '      const upReq = requestFn(\n        {\n          hostname: upstream.hostname,\n          port: upstream.port,\n          path: upstream.basePath + req.url,'
)

open(path, 'w').write(text)
print("patched")
PYEOF
  ok "server.js patched"
fi

# ── 5. Установить headroom ──────────────────────────────────────────────────
step "Installing headroom"

if [[ -x "$VENV_DIR/bin/headroom" ]]; then
  HEADROOM_VER=$("$VENV_DIR/bin/headroom" --version 2>/dev/null | awk '{print $NF}')
  ok "headroom already installed ($HEADROOM_VER) — skipping"
else
  echo "  Installing headroom-ai[all] into $VENV_DIR (may take a few minutes)..."
  "$PYTHON" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install "headroom-ai[all]" -q
  HEADROOM_VER=$("$VENV_DIR/bin/headroom" --version 2>/dev/null | awk '{print $NF}')
  ok "headroom $HEADROOM_VER installed"
fi

# ── 6. Записать start-with-jbcentral.sh ─────────────────────────────────────
step "Writing start-with-jbcentral.sh"

LAUNCHER="$PINO_DIR/start-with-jbcentral.sh"

cat > "$LAUNCHER" <<LAUNCHER_EOF
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

PINO_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
ENTRY_PORT=8787
SECONDARY_PORT=8788
HEADROOM_BIN="$VENV_DIR/bin/headroom"

MODE_FILE="\$HOME/.claude/proxy-mode"
MODE="\${PROXY_MODE:-\$(cat "\$MODE_FILE" 2>/dev/null || echo "pino")}"

KEY=\$(jbcentral proxy start --ensure-updated --return-key)
JBC_URL="http://127.0.0.1:19516/wire/\$KEY/claude-code/anthropic"

port_up() { nc -z 127.0.0.1 "\$1" 2>/dev/null; }

wait_port() {
  local port="\$1" tries="\${2:-30}" interval="\${3:-0.2}"
  for _ in \$(seq 1 "\$tries"); do port_up "\$port" && return 0; sleep "\$interval"; done
  return 1
}

kill_pid_file() {
  local f="\$1"
  [[ -f "\$f" ]] || return 0
  local pid; pid=\$(cat "\$f")
  kill "\$pid" 2>/dev/null || true
  rm -f "\$f"
}

start_pino() {
  local upstream="\$1" port="\$2"
  local pid_file="/tmp/pino-\${port}.pid"
  local ups_file="/tmp/pino-\${port}.upstream"

  if [[ -f "\$pid_file" ]]; then
    local pid; pid=\$(cat "\$pid_file")
    if kill -0 "\$pid" 2>/dev/null && [[ "\$(cat "\$ups_file" 2>/dev/null)" == "\$upstream" ]]; then
      return 0
    fi
    kill "\$pid" 2>/dev/null || true
    sleep 0.2
  fi

  PORT="\$port" AUTO_CACHE=1 \\
    UPSTREAM_URL="\$upstream" \\
    TRANSFORM_FILE="\$PINO_DIR/src/transforms/default.js" \\
    node "\$PINO_DIR/bin/pino-proxy.js" >> "/tmp/pino-\${port}.log" 2>&1 &

  echo \$! > "\$pid_file"
  echo "\$upstream" > "\$ups_file"
  wait_port "\$port" || { echo "pino failed to start on :\$port" >&2; exit 1; }
}

start_headroom() {
  local upstream="\$1" port="\$2"
  local pid_file="/tmp/headroom-\${port}.pid"
  local ups_file="/tmp/headroom-\${port}.upstream"

  if [[ ! -x "\$HEADROOM_BIN" ]]; then
    echo "headroom not found at \$HEADROOM_BIN" >&2
    echo "Run the installer again or: \$PYTHON -m venv $VENV_DIR && $VENV_DIR/bin/pip install 'headroom-ai[all]'" >&2
    exit 1
  fi

  if [[ -f "\$pid_file" ]]; then
    local pid; pid=\$(cat "\$pid_file")
    if kill -0 "\$pid" 2>/dev/null && [[ "\$(cat "\$ups_file" 2>/dev/null)" == "\$upstream" ]]; then
      return 0
    fi
    kill "\$pid" 2>/dev/null || true
    sleep 0.5
  fi

  "\$HEADROOM_BIN" proxy --port "\$port" --anthropic-api-url "\$upstream" \\
    >> "/tmp/headroom-\${port}.log" 2>&1 &

  echo \$! > "\$pid_file"
  echo "\$upstream" > "\$ups_file"
  wait_port "\$port" 60 0.5 || { echo "headroom failed to start on :\$port" >&2; exit 1; }
}

case "\$MODE" in
  pino)
    kill_pid_file "/tmp/headroom-\${ENTRY_PORT}.pid"
    kill_pid_file "/tmp/pino-\${SECONDARY_PORT}.pid"
    start_pino "\$JBC_URL" "\$ENTRY_PORT"
    ;;
  headroom)
    kill_pid_file "/tmp/pino-\${ENTRY_PORT}.pid"
    kill_pid_file "/tmp/pino-\${SECONDARY_PORT}.pid"
    start_headroom "\$JBC_URL" "\$ENTRY_PORT"
    ;;
  headroom+pino)
    # правильный порядок: headroom сжимает, pino добавляет 1h кеш
    kill_pid_file "/tmp/pino-\${ENTRY_PORT}.pid"
    start_pino "\$JBC_URL" "\$SECONDARY_PORT"
    start_headroom "http://127.0.0.1:\$SECONDARY_PORT" "\$ENTRY_PORT"
    ;;
  *)
    echo "Unknown mode: '\$MODE' — valid: pino | headroom | headroom+pino" >&2
    exit 1
    ;;
esac

echo "\$KEY"
LAUNCHER_EOF

chmod +x "$LAUNCHER"
ok "launcher written → $LAUNCHER"

# ── 7. Обновить ~/.claude/settings.json ─────────────────────────────────────
step "Updating Claude Code settings"

mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi

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

if changed:
    print("updated: " + ", ".join(changed))
else:
    print("already up to date")
PYEOF

ok "settings.json updated"

# ── 8. Дефолтный режим ──────────────────────────────────────────────────────
step "Setting default proxy mode"

if [[ -f "$MODE_FILE" ]]; then
  ok "proxy-mode already set: $(cat "$MODE_FILE")"
else
  echo "pino" > "$MODE_FILE"
  ok "proxy-mode set to: pino"
fi

# ── Готово ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo ""
echo "  Текущий режим: $(cat "$MODE_FILE")"
echo ""
echo "  Переключить режим:"
echo "    echo \"pino\"          > ~/.claude/proxy-mode   # cache injection only"
echo "    echo \"headroom\"      > ~/.claude/proxy-mode   # context compression only"
echo "    echo \"headroom+pino\" > ~/.claude/proxy-mode   # compression + cache (recommended)"
echo ""
echo "  Статистика (когда запущен headroom+pino или headroom):"
echo "    curl -s http://127.0.0.1:8787/stats | python3 -m json.tool"
echo ""
echo "  Логи:"
echo "    tail -f /tmp/pino-8787.log"
echo "    tail -f /tmp/headroom-8787.log"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
