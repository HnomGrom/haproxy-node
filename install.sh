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
    maxconn 100000
    nbthread 4
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option tcp-smart-accept
    timeout connect 3s
    timeout client  30m
    timeout server  30m
    timeout tunnel  1h
    timeout client-fin 10s
    timeout server-fin 10s

# Shared abuse-detection table (per source IP, across all frontends)
backend abuse_table
    stick-table type ipv6 size 1m expire 30m store conn_rate(10s),conn_cur,sess_rate(10s),gpc0,gpc0_rate(1m)

frontend fallback_error
    bind *:${FALLBACK_PORT}
    mode http
    timeout client 10s
    http-request return status 503 content-type "text/html; charset=utf-8" file /etc/haproxy/errors/503.html
HAPCFG

systemctl enable haproxy
systemctl restart haproxy

# ───────────────────────── Kernel tuning (sysctl) ─────────
log "Applying kernel DDoS protection (sysctl)..."
cat > /etc/sysctl.d/99-haproxy-ddos.conf <<'SYSCTL'
# SYN-flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3

# Conntrack sizing (needed for connlimit / high connection counts)
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# TCP tuning for long-lived VLESS connections
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Anti-spoofing / bogus traffic
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
SYSCTL

# Load nf_conntrack module so conntrack sysctl keys exist before we apply
modprobe nf_conntrack 2>/dev/null || true
sysctl --system >/dev/null || warn "sysctl --system returned non-zero (non-fatal)"

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

# ───────────────────────── iptables filter (DDoS) ─────────
log "Setting up iptables filter rules (SYN-flood, connlimit, scan blocking)..."

# Idempotent: drop our chain if it already exists, then recreate
iptables -D INPUT -j HAPROXY_DDOS 2>/dev/null || true
iptables -F HAPROXY_DDOS 2>/dev/null || true
iptables -X HAPROXY_DDOS 2>/dev/null || true
iptables -N HAPROXY_DDOS

# Fast path: pass ESTABLISHED,RELATED without further checks
iptables -A HAPROXY_DDOS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# Drop invalid packets (malformed / out-of-state)
iptables -A HAPROXY_DDOS -m conntrack --ctstate INVALID -j DROP

# Drop stealth / malformed TCP scans
iptables -A HAPROXY_DDOS -p tcp --tcp-flags ALL NONE -j DROP
iptables -A HAPROXY_DDOS -p tcp --tcp-flags ALL ALL  -j DROP
iptables -A HAPROXY_DDOS -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A HAPROXY_DDOS -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
iptables -A HAPROXY_DDOS -p tcp --tcp-flags FIN,RST FIN,RST -j DROP

# Per-IP connection limit on VLESS frontend port range (prevents connection flood)
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
  -m connlimit --connlimit-above 20 --connlimit-mask 32 -j DROP

# Global SYN-flood rate limit on VLESS ports (in addition to syncookies)
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
  -m limit --limit 200/s --limit-burst 400 -j RETURN
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j DROP

# ICMP rate limit (keep ping usable but cheap to abuse)
iptables -A HAPROXY_DDOS -p icmp -m limit --limit 5/s --limit-burst 10 -j RETURN
iptables -A HAPROXY_DDOS -p icmp -j DROP

# Attach DDoS chain at the top of INPUT so it runs before any other rule
iptables -I INPUT 1 -j HAPROXY_DDOS

# Persist iptables rules across reboots (filter + nat tables)
if ! command -v netfilter-persistent &>/dev/null; then
  log "Installing iptables-persistent for rule persistence..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
fi
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
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
