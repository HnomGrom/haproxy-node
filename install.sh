#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/haproxy-node"
REPO_URL="https://github.com/HnomGrom/haproxy-node.git"
# Ветка по умолчанию — main. Переопределяется env-переменной (REPO_BRANCH или
# короткий alias BRANCH) либо интерактивным prompt'ом ниже.
# Примеры:
#   REPO_BRANCH=develop bash install.sh
#   BRANCH=develop bash install.sh
REPO_BRANCH_DEFAULT="${REPO_BRANCH:-${BRANCH:-main}}"
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

read -rp "Git branch [${REPO_BRANCH_DEFAULT}]: " REPO_BRANCH
REPO_BRANCH="${REPO_BRANCH:-${REPO_BRANCH_DEFAULT}}"

# IP, которым разрешён доступ к API (:${API_PORT}) через запятую.
# Пусто = API ЗАКРЫТ (только с localhost).
read -rp "IPv4 (через запятую) с доступом к API [пусто = закрыт]: " API_ALLOWED_IPS
read -rp "IPv6 (через запятую) с доступом к API [пусто = нет]: " API_ALLOWED_IPS_V6

# IP, которым разрешён SSH. Пусто = все (с rate-limit 4/мин).
read -rp "IPv4 (через запятую) с доступом к SSH :22 [пусто = все]: " SSH_ALLOWED_IPS
read -rp "IPv6 (через запятую) с доступом к SSH [пусто = все]: " SSH_ALLOWED_IPS_V6

# Защита от самоблокировки: автоматически добавить текущий SSH IP
# (в IPv4 или IPv6 whitelist — в зависимости от протокола текущей сессии)
CUR_SSH_IP=""
if [ -n "${SSH_CLIENT:-}" ]; then
  CUR_SSH_IP="${SSH_CLIENT%% *}"
elif [ -n "${SSH_CONNECTION:-}" ]; then
  CUR_SSH_IP="${SSH_CONNECTION%% *}"
fi

if [ -n "${CUR_SSH_IP}" ]; then
  if [[ "${CUR_SSH_IP}" == *:* ]]; then
    # IPv6
    if [ -n "${SSH_ALLOWED_IPS_V6}" ] && ! echo ",${SSH_ALLOWED_IPS_V6}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv6 SSH в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6},${CUR_SSH_IP}"
    fi
  else
    # IPv4
    if [ -n "${SSH_ALLOWED_IPS}" ] && ! echo ",${SSH_ALLOWED_IPS}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv4 SSH в whitelist: ${CUR_SSH_IP}"
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
  log "Updating existing installation (branch: ${REPO_BRANCH})..."
  cd "$APP_DIR"
  git fetch --all --prune || true
  # Если нужная ветка уже локально — switch, иначе создаём локальную от origin/<branch>
  if git show-ref --verify --quiet "refs/heads/${REPO_BRANCH}"; then
    git checkout "${REPO_BRANCH}" || warn "git checkout ${REPO_BRANCH} failed"
  else
    git checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}" || warn "branch ${REPO_BRANCH} not found on remote"
  fi
  git pull --ff-only origin "${REPO_BRANCH}" || warn "git pull failed (possibly divergent history — check manually)"
else
  log "Cloning repository (branch: ${REPO_BRANCH})..."
  rm -rf "$APP_DIR"
  git clone --branch "${REPO_BRANCH}" "$REPO_URL" "$APP_DIR" || \
    err "git clone failed — ветка '${REPO_BRANCH}' существует в ${REPO_URL}?"
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
API_ALLOWED_IPS="${API_ALLOWED_IPS}"
API_ALLOWED_IPS_V6="${API_ALLOWED_IPS_V6}"
SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS}"
SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6}"
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
HAPCFG

systemctl enable haproxy
systemctl restart haproxy

# ───────────────────────── Kernel tuning (sysctl) ─────────
log "Applying kernel DDoS protection (sysctl)..."
cat > /etc/sysctl.d/99-haproxy-ddos.conf <<'SYSCTL'
# SYN-flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2

# Conntrack под нагрузку (4M записей)
net.netfilter.nf_conntrack_max = 4194304
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5

# TCP tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_keepalive_time = 300

# BBR для мобильных
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
SYSCTL

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || warn "sysctl --system returned non-zero (non-fatal)"

# ───────────────────────── Cleanup legacy NAT fallback ────
# Раньше трафик на неизвестные порты редиректился на FALLBACK_PORT через NAT —
# это делало HAProxy мишенью для сканеров. Теперь неизвестные порты дропаются
# policy INPUT DROP. Чистим старую цепочку если осталась.
log "Removing legacy NAT fallback chain (if exists)..."
iptables -t nat -D PREROUTING -p tcp -j HAPROXY_FALLBACK 2>/dev/null || true
iptables -t nat -F HAPROXY_FALLBACK 2>/dev/null || true
iptables -t nat -X HAPROXY_FALLBACK 2>/dev/null || true

# ───────────────────────── Install ipset + persistence ───
# ipset нужен всегда (для vless_lockdown + api/ssh whitelist).
# ipset-persistent — плагин netfilter-persistent, читает /etc/ipset.conf
# при boot ДО iptables-restore (иначе правила с match-set ссылаются на
# несуществующие set'ы и iptables-restore падает).
if ! command -v ipset &>/dev/null; then
  log "Installing ipset + ipset-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset ipset-persistent >/dev/null 2>&1 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset >/dev/null
fi
# ipset-persistent отдельно — пакет мог быть не установлен на уже
# существующем сервере с ipset.
if ! dpkg -s ipset-persistent >/dev/null 2>&1; then
  log "Installing ipset-persistent (plugin for netfilter-persistent)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset-persistent >/dev/null 2>&1 || \
    warn "ipset-persistent package not available — ipsets могут не восстановиться после reboot"
fi

# ───────────────────────── API whitelist (ipset) ──────────
if [ -n "${API_ALLOWED_IPS}" ]; then
  log "Configuring API whitelist for :${API_PORT}..."
  ipset create api_whitelist hash:net maxelem 128 2>/dev/null || true
  ipset flush api_whitelist
  ipset add api_whitelist 127.0.0.1 2>/dev/null || true
  IFS=',' read -ra _IPS <<< "${API_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${_IPS[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add api_whitelist "$ip" 2>/dev/null; then
      log "  + API allow: $ip"
    else
      warn "  ? invalid/duplicate: $ip"
    fi
  done
fi

# ───────────────────────── SSH whitelist (ipset) ──────────
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  log "Configuring SSH whitelist for :22..."
  ipset create ssh_whitelist hash:net maxelem 128 2>/dev/null || true
  ipset flush ssh_whitelist
  IFS=',' read -ra _IPS <<< "${SSH_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${_IPS[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add ssh_whitelist "$ip" 2>/dev/null; then
      log "  + SSH allow: $ip"
    else
      warn "  ? invalid/duplicate: $ip"
    fi
  done
fi

# ───────────────────────── INPUT Lockdown (policy DROP) ───
log "Lockdown: rebuilding INPUT chain with policy DROP..."

# Policy ACCEPT перед flush — не разрываем SSH при переустановке
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F INPUT

# 1. Loopback + ESTABLISHED/INVALID
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 2. SSH — whitelist или rate-limit
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  iptables -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist src -j ACCEPT
  log "  ACCEPT :22 только для ssh_whitelist"
else
  iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --set --name SSH --rsource
  iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  log "  ACCEPT :22 всем с rate-limit (4/60s)"
fi

# 3. API — только для api_whitelist
if [ -n "${API_ALLOWED_IPS}" ]; then
  iptables -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist src -j ACCEPT
  log "  ACCEPT :${API_PORT} только для api_whitelist"
else
  warn "  :${API_PORT} API ЗАКРЫТ (нет API_ALLOWED_IPS)"
fi

# 4. VLESS frontend-диапазон
iptables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

# 5. ICMP с rate-limit
iptables -A INPUT -p icmp -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# 6. Policy DROP — всё остальное в чёрную дыру
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

log "INPUT policy DROP активна. Открыто: :22, :${PORT_MIN}-${PORT_MAX}"
[ -n "${API_ALLOWED_IPS}" ] && log "  + :${API_PORT} для whitelist"

# ───────────────────────── IPv6 Lockdown ──────────────────
IPV6_ENABLED=false
if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  IPV6_ENABLED=true
fi

if [ "${IPV6_ENABLED}" = "true" ]; then
  log "IPv6 активен — применяю lockdown ip6tables..."

  # API v6 whitelist
  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    ipset create api_whitelist6 hash:net family inet6 maxelem 128 2>/dev/null || true
    ipset flush api_whitelist6
    ipset add api_whitelist6 ::1 2>/dev/null || true
    IFS=',' read -ra _IPS <<< "${API_ALLOWED_IPS_V6//[[:space:]]/}"
    for ip in "${_IPS[@]}"; do
      [ -z "$ip" ] && continue
      ipset add api_whitelist6 "$ip" 2>/dev/null && log "  + API v6 allow: $ip" || warn "  ? bad v6: $ip"
    done
  fi

  # SSH v6 whitelist
  if [ -n "${SSH_ALLOWED_IPS_V6}" ]; then
    ipset create ssh_whitelist6 hash:net family inet6 maxelem 128 2>/dev/null || true
    ipset flush ssh_whitelist6
    IFS=',' read -ra _IPS <<< "${SSH_ALLOWED_IPS_V6//[[:space:]]/}"
    for ip in "${_IPS[@]}"; do
      [ -z "$ip" ] && continue
      ipset add ssh_whitelist6 "$ip" 2>/dev/null && log "  + SSH v6 allow: $ip" || warn "  ? bad v6: $ip"
    done
  fi

  # Policy ACCEPT перед flush — не разрываем IPv6 SSH при переустановке
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -F INPUT

  # 1. Loopback + ESTABLISHED/INVALID
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

  # 2. ICMPv6 — КРИТИЧНО, без этого IPv6 сеть сломается (NDP/RA/PMTU)
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

  # 3. SSH — whitelist или rate-limit
  if [ -n "${SSH_ALLOWED_IPS_V6}" ]; then
    ip6tables -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist6 src -j ACCEPT
    log "  ACCEPT :22 (v6) только для ssh_whitelist6"
  else
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --set --name SSH6 --rsource
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --update --seconds 60 --hitcount 4 --name SSH6 --rsource -j DROP
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
    log "  ACCEPT :22 (v6) всем с rate-limit (4/60s)"
  fi

  # 4. API v6 — только для api_whitelist6
  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    ip6tables -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist6 src -j ACCEPT
    log "  ACCEPT :${API_PORT} (v6) только для api_whitelist6"
  fi

  # 5. VLESS frontend-диапазон
  ip6tables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

  # 6. Policy DROP
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT

  log "IPv6 INPUT policy DROP активна"
else
  warn "IPv6 не активен на сервере (ip6tables недоступен) — пропускаю IPv6 защиту"
fi

# ───────────────────────── Lockdown ipset (vless_lockdown) ─
# Pre-create set с hash:net (поддерживает точные IP + CIDR-диапазоны).
# Параметры должны совпадать с src/lockdown/lockdown.service.ts (MAX_ELEM, HASH_SIZE).
log "Ensuring vless_lockdown ipset (hash:net)..."

# `|| true` в конце pipe'а — защита от `set -e`:
#   1. На чистой установке `ipset list vless_lockdown` возвращает exit=1 (set'а нет).
#   2. `awk '... exit'` останавливает обработку после первого совпадения —
#      без `head -n1`, который провоцирует SIGPIPE и exit=141 под pipefail.
EXISTING_TYPE=$(ipset list vless_lockdown 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}' || true)
if [ -n "$EXISTING_TYPE" ] && [ "$EXISTING_TYPE" != "hash:net" ]; then
  warn "Found vless_lockdown with wrong type ($EXISTING_TYPE) — recreating as hash:net"
  # Снять iptables-правила, ссылающиеся на set (иначе destroy падает "in use")
  iptables -D INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m set --match-set vless_lockdown src -j ACCEPT 2>/dev/null || true
  ipset destroy vless_lockdown
fi
ipset create vless_lockdown hash:net maxelem 1000000 hashsize 65536 family inet -exist

FINAL_TYPE=$(ipset list vless_lockdown | awk -F': ' '/^Type/ {print $2; exit}' || true)
if [ "$FINAL_TYPE" != "hash:net" ]; then
  err "vless_lockdown has type '$FINAL_TYPE', expected hash:net"
fi

# ───────────────────────── ipset persistence ──────────────
# Сохранить все ipsets (api_whitelist, ssh_whitelist, vless_lockdown, *6) в /etc/ipset.conf
ipset save > /etc/ipset.conf 2>/dev/null || true

# Fallback для старых ifupdown систем (Debian pre-systemd-networkd).
# На современных Ubuntu/netplan не срабатывает — нужен ipset-persistent плагин.
if [ ! -f /etc/network/if-pre-up.d/ipset-restore ]; then
  cat > /etc/network/if-pre-up.d/ipset-restore <<'IPSETR'
#!/bin/sh
[ -f /etc/ipset.conf ] && /sbin/ipset restore < /etc/ipset.conf
exit 0
IPSETR
  chmod +x /etc/network/if-pre-up.d/ipset-restore
fi

# Persist iptables + ip6tables rules across reboots
if ! command -v netfilter-persistent &>/dev/null; then
  log "Installing iptables-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null
fi

# Плагины netfilter-persistent запускаются в алфавитном порядке.
# ipset-plugin (по умолчанию может быть назван 10-ipset или 25-ipset и т.д.)
# должен выполниться ДО iptables-plugin (обычно 15-iptables), иначе
# iptables-restore падает на правилах с --match-set (set'а ещё нет).
# Переименовываем plugin'ы: iptables становится 50-*, ip6tables 55-*,
# чтобы любой реально установленный ipset-плагин (05/10/25/45) отработал раньше.
PLUGINS_DIR="/usr/share/netfilter-persistent/plugins.d"
if [ -d "${PLUGINS_DIR}" ]; then
  # ipset-плагин в приоритет — префикс 05
  for p in "${PLUGINS_DIR}"/*-ipset; do
    [ -e "$p" ] || continue
    base=$(basename "$p" | sed -E 's/^[0-9]+-//')
    target="${PLUGINS_DIR}/05-${base}"
    if [ "$p" != "$target" ]; then
      mv "$p" "$target"
      log "Moved ipset plugin to 05-${base} (runs before iptables at boot)"
    fi
  done
fi

if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save >/dev/null 2>&1
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
