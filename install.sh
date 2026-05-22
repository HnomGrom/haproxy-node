#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/haproxy-node"
REPO_URL="https://github.com/HnomGrom/haproxy-node.git"
REPO_BRANCH="main"
SERVICE_NAME="haproxy-node"
NODE_MAJOR=22

# ───────────────────────── Colors ─────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ───────────────────────── Root check ─────────────────────
[[ $EUID -eq 0 ]] || err "Run this script as root: sudo bash install.sh"

# ───────────────────────── OS check ───────────────────────
if ! command -v apt-get &>/dev/null; then
  err "This script supports Debian/Ubuntu only"
fi

# ───────────────────────── Config (env or prompt) ─────────
# Поддерживаются env-переменные: API_KEY, API_PORT, FRONTEND_PORT_MIN, FRONTEND_PORT_MAX.
# Пример non-interactive запуска:
#   API_KEY=secret123 API_PORT=3000 FRONTEND_PORT_MIN=10000 FRONTEND_PORT_MAX=65000 \
#     bash install.sh
#
# Если переменная задана в env — prompt не показывается. Иначе спрашиваем.

if [ -z "${API_KEY:-}" ]; then
  # -s: ключ не печатается в терминале (история, scrollback, screen-recording).
  read -rsp "API key for the service: " API_KEY
  echo
fi
[[ -n "${API_KEY}" ]] || err "API key cannot be empty"
[[ ${#API_KEY} -ge 8 ]] || err "API key must be ≥8 characters (Joi-валидация на старте сервиса требует это же)"

if [ -z "${API_PORT:-}" ]; then
  read -rp "API port [3000]: " API_PORT
fi
API_PORT="${API_PORT:-3000}"

if [ -z "${FRONTEND_PORT_MIN:-}" ]; then
  read -rp "Frontend port range min [10000]: " FRONTEND_PORT_MIN
fi
FRONTEND_PORT_MIN="${FRONTEND_PORT_MIN:-10000}"

if [ -z "${FRONTEND_PORT_MAX:-}" ]; then
  read -rp "Frontend port range max [65000]: " FRONTEND_PORT_MAX
fi
FRONTEND_PORT_MAX="${FRONTEND_PORT_MAX:-65000}"

# ───────────────────────── Install system deps ────────────
log "Updating packages..."
apt-get update -qq

log "Installing HAProxy, Git, ipset..."
# ipset нужен runtime для LockdownService (src/lockdown) — он создаёт
# ipset'ы на старте приложения и при POST /lockdown/on. Это часть приложения,
# а не firewall, поэтому ставится здесь, а не в ddos.sh.
apt-get install -y -qq haproxy curl git ipset

# ───────────────────────── Install Node.js ────────────────
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt $NODE_MAJOR ]]; then
  log "Installing Node.js ${NODE_MAJOR}.x..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
else
  log "Node.js $(node -v) already installed"
fi

# ───────────────────────── Clone project ──────────────────
if [[ -d "$APP_DIR/.git" ]]; then
  log "Updating existing installation..."
  cd "$APP_DIR"
  git fetch --all --prune || true
  if git show-ref --verify --quiet "refs/heads/${REPO_BRANCH}"; then
    git checkout "${REPO_BRANCH}" || err "git checkout ${REPO_BRANCH} failed (есть локальные изменения? разреши вручную)"
  else
    git checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}" || err "branch ${REPO_BRANCH} not found on remote"
  fi
  git pull --ff-only origin "${REPO_BRANCH}" || err "git pull failed (divergent history — разреши вручную)"
else
  log "Cloning repository..."
  rm -rf "$APP_DIR"
  git clone --branch "${REPO_BRANCH}" "$REPO_URL" "$APP_DIR" || \
    err "git clone failed — ветка '${REPO_BRANCH}' существует в ${REPO_URL}?"
  cd "$APP_DIR"
fi

# ───────────────────────── Create .env ────────────────────
log "Writing .env..."
# umask 077 → файл создаётся с 0600 (rw-------). Без этого default umask 022
# даёт 0644 и API_KEY читаем любым пользователем системы.
(umask 077; cat > .env <<EOF
DATABASE_URL="file:./dev.db"
API_KEY="${API_KEY}"
HAPROXY_CONFIG_PATH="/etc/haproxy/haproxy.cfg"
PORT=${API_PORT}
FRONTEND_PORT_MIN=${FRONTEND_PORT_MIN}
FRONTEND_PORT_MAX=${FRONTEND_PORT_MAX}
ERROR_PAGE_PATH="/etc/haproxy/errors/503.html"
EOF
)
chown root:root .env
chmod 600 .env

# ───────────────────────── Install & build ────────────────
log "Installing npm dependencies..."
cd "${APP_DIR}" && NODE_ENV=development npm install

log "Generating Prisma client..."
cd "${APP_DIR}" && npx prisma generate

log "Syncing database schema..."
# ВАЖНО: используем `db push`, а не `migrate deploy`.
#
# Причина: `migrate deploy` применяет ТОЛЬКО миграции, закоммиченные в git
# (prisma/migrations/*). Если в schema.prisma появилась модель, но соответствующая
# миграция не закоммичена — таблица в проде не будет создана. `db push` читает
# schema.prisma напрямую и приводит БД в соответствие — идемпотентно, безопасно
# для additive-изменений. --accept-data-loss нужен чтобы скрипт не висел на
# prompt'е, если бы вдруг потребовалось удалить столбец.

# Pre-check: новый @@unique([ip, backendPort]) constraint в Server упадёт,
# если в существующей БД уже есть дубли. Detect & report ДО `db push` —
# иначе оператор получит непонятный "UNIQUE constraint failed".
if [ -f "${APP_DIR}/dev.db" ] && command -v sqlite3 &>/dev/null; then
  DUPS=$(sqlite3 "${APP_DIR}/dev.db" "SELECT ip, backendPort, COUNT(*) c FROM Server GROUP BY ip, backendPort HAVING c > 1;" 2>/dev/null || true)
  if [ -n "${DUPS}" ]; then
    warn "В БД найдены дубликаты (ip, backendPort) — миграция упадёт на @@unique:"
    echo "${DUPS}" | sed 's/^/    /'
    err "Удали дубли вручную: sqlite3 ${APP_DIR}/dev.db \"DELETE FROM Server WHERE id NOT IN (SELECT MIN(id) FROM Server GROUP BY ip, backendPort);\""
  fi
fi

cd "${APP_DIR}" && npx prisma db push --accept-data-loss \
  || err "Prisma db push failed — БД схема не синхронизирована с schema.prisma"

log "Building application..."
cd "${APP_DIR}"
rm -rf "${APP_DIR}/dist"
./node_modules/.bin/tsc -p tsconfig.build.json || err "TypeScript compilation failed"
[[ -f "${APP_DIR}/dist/src/main.js" ]] || err "Build failed — dist/src/main.js not found"
log "Build successful"

# ───────────────────────── HAProxy initial config ─────────
# Минимальная начальная конфигурация. Приложение (NestJS) перегенерирует
# /etc/haproxy/haproxy.cfg при первом CRUD-вызове (add/remove server) —
# тогда же появится backend abuse_table и frontend-блоки.
if [[ ! -f /etc/haproxy/haproxy.cfg.original ]]; then
  log "Backing up original HAProxy config..."
  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.original
fi

log "Writing initial HAProxy config..."
# nbthread — число CPU ядер (HAProxy 2.8 не принимает 'auto')
NBTHREAD=$(nproc 2>/dev/null || echo 4)
[ "${NBTHREAD}" -gt 64 ] 2>/dev/null && NBTHREAD=64
cat > /etc/haproxy/haproxy.cfg <<HAPCFG
global
    log /dev/log local0
    maxconn 200000
    nbthread ${NBTHREAD}
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option tcp-smart-accept
    option redispatch
    retries 3
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  24h
    timeout client-fin 10s
    timeout server-fin 10s
    timeout queue   30s
HAPCFG

# Поднять systemd-лимиты для HAProxy чтобы он мог открыть 500k файлов
mkdir -p /etc/systemd/system/haproxy.service.d
cat > /etc/systemd/system/haproxy.service.d/override.conf <<'SYSD'
[Service]
LimitNOFILE=500000
LimitNPROC=500000
SYSD
systemctl daemon-reload

systemctl enable haproxy
systemctl restart haproxy

# ───────────────────────── Systemd service ────────────────
log "Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=HAProxy Node Management API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(which node) ${APP_DIR}/dist/src/main.js
Restart=on-failure
RestartSec=5
EnvironmentFile=${APP_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# ───────────────────────── Done ───────────────────────────
log "Installation complete!"
echo ""
echo "  API running on port ${API_PORT}"
echo "  Service:  systemctl status ${SERVICE_NAME}"
echo "  Logs:     journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "  Usage:"
echo "    curl -H 'x-api-key: ${API_KEY}' http://localhost:${API_PORT}/servers"
echo ""
echo "  Для защиты от DDoS, SSH brute-force, SNI-фильтра и т.п. запусти отдельно:"
echo "    sudo bash ${APP_DIR}/ddos.sh"
echo ""
