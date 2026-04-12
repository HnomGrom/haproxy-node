#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/haproxy-node"
REPO_URL="https://github.com/HnomGrom/haproxy-node.git"
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

# ───────────────────────── Prompt config ──────────────────
read -rp "API key for the service: " API_KEY
[[ -n "$API_KEY" ]] || err "API key cannot be empty"

read -rp "API port [3000]: " API_PORT
API_PORT="${API_PORT:-3000}"

read -rp "Frontend port range min [10000]: " PORT_MIN
PORT_MIN="${PORT_MIN:-10000}"

read -rp "Frontend port range max [65000]: " PORT_MAX
PORT_MAX="${PORT_MAX:-65000}"

read -rp "Fallback error page port [59999]: " FALLBACK_PORT
FALLBACK_PORT="${FALLBACK_PORT:-59999}"

# ───────────────────────── Install system deps ────────────
log "Updating packages..."
apt-get update -qq

log "Installing HAProxy and Git..."
apt-get install -y -qq haproxy curl git

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
  git pull --ff-only || true
else
  log "Cloning repository..."
  rm -rf "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
  cd "$APP_DIR"
fi

# ───────────────────────── Create .env ────────────────────
log "Writing .env..."
cat > .env <<EOF
DATABASE_URL="file:./dev.db"
API_KEY="${API_KEY}"
HAPROXY_CONFIG_PATH="/etc/haproxy/haproxy.cfg"
PORT=${API_PORT}
FRONTEND_PORT_MIN=${PORT_MIN}
FRONTEND_PORT_MAX=${PORT_MAX}
FALLBACK_PORT=${FALLBACK_PORT}
ERROR_PAGE_PATH="/etc/haproxy/errors/503.html"
EOF

# ───────────────────────── Install & build ────────────────
log "Installing npm dependencies..."
cd "${APP_DIR}" && NODE_ENV=development npm install

log "Generating Prisma client..."
cd "${APP_DIR}" && npx prisma generate

log "Running database migrations..."
cd "${APP_DIR}" && npx prisma migrate deploy

log "Building application..."
cd "${APP_DIR}"
rm -rf "${APP_DIR}/dist"
./node_modules/.bin/tsc -p tsconfig.build.json || err "TypeScript compilation failed"
[[ -f "${APP_DIR}/dist/src/main.js" ]] || err "Build failed — dist/src/main.js not found"
log "Build successful"

# ───────────────────────── Error page ─────────────────────
log "Installing error page..."
mkdir -p /etc/haproxy/errors
cp "${APP_DIR}/src/haproxy/error-pages/503.html" /etc/haproxy/errors/503.html

# ───────────────────────── HAProxy initial config ─────────
if [[ ! -f /etc/haproxy/haproxy.cfg.original ]]; then
  log "Backing up original HAProxy config..."
  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.original
fi

log "Writing initial HAProxy config..."
cat > /etc/haproxy/haproxy.cfg <<HAPCFG
global
    log /dev/log local0
    maxconn 50000
    daemon

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    timeout client-fin 30s
    timeout server-fin 30s

frontend fallback_error
    bind *:${FALLBACK_PORT}
    mode http
    timeout client 10s
    http-request return status 503 content-type "text/html; charset=utf-8" file /etc/haproxy/errors/503.html
HAPCFG

systemctl enable haproxy
systemctl restart haproxy

# ───────────────────────── iptables fallback rules ────────
log "Setting up iptables fallback rules..."
iptables -t nat -N HAPROXY_FALLBACK 2>/dev/null || iptables -t nat -F HAPROXY_FALLBACK

# Protect system ports
iptables -t nat -A HAPROXY_FALLBACK -p tcp --dport 22 -j RETURN
iptables -t nat -A HAPROXY_FALLBACK -p tcp --dport ${API_PORT} -j RETURN
iptables -t nat -A HAPROXY_FALLBACK -p tcp --dport ${FALLBACK_PORT} -j RETURN

# Redirect everything else to fallback
iptables -t nat -A HAPROXY_FALLBACK -p tcp -j REDIRECT --to-port ${FALLBACK_PORT}

# Attach to PREROUTING if not already
if ! iptables -t nat -S PREROUTING | grep -q "HAPROXY_FALLBACK"; then
  iptables -t nat -A PREROUTING -p tcp -j HAPROXY_FALLBACK
fi

# Persist iptables rules across reboots
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

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
