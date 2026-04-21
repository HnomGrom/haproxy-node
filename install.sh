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

# IP-адреса, которым разрешён доступ к API (через запятую).
# Пусто = API полностью закрыт (только с localhost).
# Пример: 38.180.122.151,203.0.113.5
read -rp "IPv4 (через запятую) с доступом к API, например IP панели Remnawave [пусто = закрыт]: " API_ALLOWED_IPS

# IPv6 адреса панели / админа (опционально)
read -rp "IPv6 (через запятую) с доступом к API [пусто = нет]: " API_ALLOWED_IPS_V6

# SNI whitelist — разрешённые имена в TLS ClientHello. Атакующие с чужим SNI
# или без SNI → reject + 30-мин бан. Пусто = SNI-фильтр выключен.
# Пример для Reality: www.microsoft.com,yahoo.com,www.apple.com
read -rp "Разрешённые SNI (через запятую) [пусто = без фильтра]: " ALLOWED_SNI

# SSH whitelist — только указанные IP смогут подключаться по SSH (:22).
# Защищает от brute-force. Ваш текущий SSH IP добавляется автоматически.
# Пусто = SSH открыт всем (с rate-limit 4 попытки/мин на IP).
# Пример: 107.189.26.23,203.0.113.5,10.0.0.0/24
read -rp "IPv4 (через запятую) с доступом к SSH :22 [пусто = все + rate-limit]: " SSH_ALLOWED_IPS
read -rp "IPv6 с доступом к SSH [пусто = все]: " SSH_ALLOWED_IPS_V6

# Защита от самоблокировки: автоматически добавить текущий SSH IP в whitelist
# (берём из SSH_CLIENT / SSH_CONNECTION если есть)
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  CUR_SSH_IP=""
  if [ -n "${SSH_CLIENT:-}" ]; then
    CUR_SSH_IP="${SSH_CLIENT%% *}"
  elif [ -n "${SSH_CONNECTION:-}" ]; then
    CUR_SSH_IP="${SSH_CONNECTION%% *}"
  fi
  if [ -n "${CUR_SSH_IP}" ] && [[ "${CUR_SSH_IP}" != *:* ]]; then
    if ! echo ",${SSH_ALLOWED_IPS}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автоматически добавляю ваш текущий SSH IP в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS},${CUR_SSH_IP}"
    fi
  fi
fi

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
API_ALLOWED_IPS="${API_ALLOWED_IPS}"
API_ALLOWED_IPS_V6="${API_ALLOWED_IPS_V6}"
SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS}"
SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6}"
ALLOWED_SNI="${ALLOWED_SNI}"
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

# Conntrack sizing — 4M, под атаку 135k pps при 60s timeout
net.netfilter.nf_conntrack_max = 4194304
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10

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

# ───────────────────────── Cleanup old NAT fallback ───────
# Раньше трафик на неизвестные порты редиректился на FALLBACK_PORT через NAT.
# Это делало HAProxy мишенью для сканеров. Теперь неизвестные порты дропаются
# естественно (RST от ядра / INPUT DROP). Чистим старую цепочку если осталась.
log "Removing legacy NAT fallback chain..."
iptables -t nat -D PREROUTING -p tcp -j HAPROXY_FALLBACK 2>/dev/null || true
iptables -t nat -F HAPROXY_FALLBACK 2>/dev/null || true
iptables -t nat -X HAPROXY_FALLBACK 2>/dev/null || true

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

# HAPROXY_DDOS будет привязана к INPUT в lockdown-блоке ниже,
# одновременно с policy DROP и whitelist-правилами

# ───────────────────────── ip6tables filter (DDoS) ────────
# Проверяем что IPv6 работает на сервере
IPV6_ENABLED=false
if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  IPV6_ENABLED=true
  log "Setting up ip6tables filter rules (same as IPv4)..."

  # Idempotent
  ip6tables -D INPUT -j HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -F HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -X HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -N HAPROXY_DDOS6

  # Fast path для ESTABLISHED
  ip6tables -A HAPROXY_DDOS6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

  # INVALID drop
  ip6tables -A HAPROXY_DDOS6 -m conntrack --ctstate INVALID -j DROP

  # TCP scan flags (SYN+FIN, SYN+RST, FIN+RST, NULL, XMAS)
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags ALL NONE -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags ALL ALL  -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags FIN,RST FIN,RST -j DROP

  # Per-IP connlimit на VLESS (mask 128 = /128 для IPv6)
  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m connlimit --connlimit-above 20 --connlimit-mask 128 -j DROP

  # SYN-flood rate limit
  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m limit --limit 200/s --limit-burst 400 -j RETURN
  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j DROP
else
  warn "IPv6 не активен на сервере (ip6tables недоступен) — пропускаю IPv6 защиту"
fi

# ───────────────────────── INPUT Lockdown (policy DROP) ──────
# Пересобираем INPUT с нуля. Всё что не в whitelist — дропается.
log "Lockdown: rebuilding INPUT chain with policy DROP + explicit whitelist..."

# ВАЖНО: сначала policy в ACCEPT — чтобы при переустановке (когда policy уже DROP)
# flush не разорвал SSH между командами
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT

# Flush старых правил INPUT (на случай переустановки).
# Делается ДО ipset destroy, иначе set "in use" не удалится.
iptables -F INPUT

# ───────────────────────── API whitelist (порт ${API_PORT}) ──────
# Создаётся после flush INPUT — старые ссылки на set уже сброшены.
# Install ipset if missing (понадобится для ЛЮБОГО whitelist: API или SSH)
if { [ -n "${API_ALLOWED_IPS}" ] || [ -n "${API_ALLOWED_IPS_V6}" ] || \
     [ -n "${SSH_ALLOWED_IPS}" ] || [ -n "${SSH_ALLOWED_IPS_V6}" ]; } && \
   ! command -v ipset &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset
fi

# IPv4 whitelist
if [ -n "${API_ALLOWED_IPS}" ]; then
  log "Configuring IPv4 API whitelist for port ${API_PORT}..."
  ipset destroy api_whitelist 2>/dev/null || true
  ipset create api_whitelist hash:net maxelem 128

  ipset add api_whitelist 127.0.0.1 2>/dev/null || true

  IFS=',' read -ra IP_LIST <<< "${API_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${IP_LIST[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add api_whitelist "$ip" 2>/dev/null; then
      log "  + allow API access (v4): $ip"
    else
      warn "  ? invalid or duplicate v4: $ip"
    fi
  done
else
  warn "API_ALLOWED_IPS (IPv4) пуст — API :${API_PORT} ЗАКРЫТ для IPv4 (policy DROP)"
fi

# SSH IPv4 whitelist
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  log "Configuring IPv4 SSH whitelist..."
  ipset destroy ssh_whitelist 2>/dev/null || true
  ipset create ssh_whitelist hash:net maxelem 128

  IFS=',' read -ra SSH_IP_LIST <<< "${SSH_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${SSH_IP_LIST[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add ssh_whitelist "$ip" 2>/dev/null; then
      log "  + allow SSH (v4): $ip"
    else
      warn "  ? invalid or duplicate v4: $ip"
    fi
  done
fi

# SSH IPv6 whitelist
if [ "${IPV6_ENABLED}" = "true" ] && [ -n "${SSH_ALLOWED_IPS_V6}" ]; then
  log "Configuring IPv6 SSH whitelist..."
  ipset destroy ssh_whitelist6 2>/dev/null || true
  ipset create ssh_whitelist6 hash:net family inet6 maxelem 128

  IFS=',' read -ra SSH_IP_LIST_V6 <<< "${SSH_ALLOWED_IPS_V6//[[:space:]]/}"
  for ip in "${SSH_IP_LIST_V6[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add ssh_whitelist6 "$ip" 2>/dev/null; then
      log "  + allow SSH (v6): $ip"
    else
      warn "  ? invalid or duplicate v6: $ip"
    fi
  done
fi

# IPv6 whitelist (API)
if [ "${IPV6_ENABLED}" = "true" ] && [ -n "${API_ALLOWED_IPS_V6}" ]; then
  log "Configuring IPv6 API whitelist for port ${API_PORT}..."
  ipset destroy api_whitelist6 2>/dev/null || true
  ipset create api_whitelist6 hash:net family inet6 maxelem 128

  ipset add api_whitelist6 ::1 2>/dev/null || true

  IFS=',' read -ra IP_LIST_V6 <<< "${API_ALLOWED_IPS_V6//[[:space:]]/}"
  for ip in "${IP_LIST_V6[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add api_whitelist6 "$ip" 2>/dev/null; then
      log "  + allow API access (v6): $ip"
    else
      warn "  ? invalid or duplicate v6: $ip"
    fi
  done
fi

# 1. HAPROXY_DDOS первой — фильтрует SYN-flood / сканы / connlimit
iptables -A INPUT -j HAPROXY_DDOS

# 2. Essentials
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 3. SSH — whitelist или rate-limit
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  # Режим whitelist: только указанные IP
  iptables -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist src -j ACCEPT
  log "  ACCEPT :22 только для ssh_whitelist"
else
  # Дефолтный режим: открыт всем с rate-limit (brute-force protection)
  iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --set --name SSH --rsource
  iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  log "  ACCEPT :22 всем с rate-limit (4 попытки/60s)"
fi

# 4. API — только для IP из api_whitelist (если задан)
if [ -n "${API_ALLOWED_IPS}" ]; then
  iptables -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist src -j ACCEPT
  log "  ACCEPT ${API_PORT}/tcp для api_whitelist"
fi

# 5. VLESS frontend-диапазон — пропускаем, внутри HAPROXY_DDOS уже стоит rate-limit
iptables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

# 6. ICMP с rate-limit (ping для диагностики)
iptables -A INPUT -p icmp -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# 7. ТЕПЕРЬ включаем Policy DROP — все правила выше уже собраны
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

log "IPv4 INPUT policy DROP активна. Открытые порты: 22 (SSH), ${PORT_MIN}-${PORT_MAX} (VLESS)"
[ -n "${API_ALLOWED_IPS}" ] && log "  + ${API_PORT} (API) — только для api_whitelist"

# ───────────────────────── IPv6 Lockdown (policy DROP) ──────
if [ "${IPV6_ENABLED}" = "true" ]; then
  log "IPv6 lockdown: rebuilding ip6tables INPUT chain with policy DROP..."

  # Policy ACCEPT перед flush — не рвём существующий IPv6 SSH
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -F INPUT

  # 1. HAPROXY_DDOS6 первой
  ip6tables -A INPUT -j HAPROXY_DDOS6

  # 2. Essentials
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

  # 3. КРИТИЧНО: ICMPv6 — нужен для Neighbor Discovery, Router Advertisement, PMTU.
  # Без этого IPv6 связь сломается (не работает NDP, MTU, link-local).
  # Разрешаем обязательные типы без лимита, всё остальное с rate-limit.
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type neighbor-solicitation -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type neighbor-advertisement -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
  # echo-request (ping6) — с rate-limit
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -m limit --limit 5/s -j ACCEPT

  # 4. SSH — whitelist или rate-limit (IPv6)
  if [ -n "${SSH_ALLOWED_IPS_V6}" ] && ipset list -n 2>/dev/null | grep -q "^ssh_whitelist6$"; then
    ip6tables -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist6 src -j ACCEPT
    log "  ACCEPT :22 (v6) только для ssh_whitelist6"
  else
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --set --name SSH6 --rsource
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --update --seconds 60 --hitcount 4 --name SSH6 --rsource -j DROP
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
  fi

  # 5. API IPv6 whitelist (если задан)
  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    ip6tables -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist6 src -j ACCEPT
    log "  ACCEPT ${API_PORT}/tcp (v6) для api_whitelist6"
  fi

  # 6. VLESS диапазон
  ip6tables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

  # 7. Policy DROP
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT

  log "IPv6 INPUT policy DROP активна"
fi

# ───────────────────────── ipset persistence ──────────────
ipset save > /etc/ipset.conf 2>/dev/null || true
if [ ! -f /etc/network/if-pre-up.d/ipset-restore ]; then
  cat > /etc/network/if-pre-up.d/ipset-restore <<'IPSET_RESTORE'
#!/bin/sh
[ -f /etc/ipset.conf ] && /sbin/ipset restore < /etc/ipset.conf
exit 0
IPSET_RESTORE
  chmod +x /etc/network/if-pre-up.d/ipset-restore
fi

# Persist iptables + ip6tables rules across reboots
if ! command -v netfilter-persistent &>/dev/null; then
  log "Installing iptables-persistent for rule persistence..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
fi
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  if [ "${IPV6_ENABLED}" = "true" ] && command -v ip6tables-save &>/dev/null; then
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
  fi
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
