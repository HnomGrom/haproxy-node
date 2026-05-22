#!/usr/bin/env bash
set -euo pipefail

# ddos.sh — отдельный скрипт для защиты сервера haproxy-node от DDoS,
# SSH brute-force, SNI-маскировки и пр. Запускается ПОСЛЕ install.sh.
#
# Что делает:
#   - kernel tuning (sysctl: SYN-flood, conntrack, BBR)
#   - iptables/ip6tables: HAPROXY_DDOS chain (SYN-flood, connlimit, scan blocking)
#   - ipset: API + SSH whitelist'ы (IPv4/IPv6)
#   - INPUT policy DROP + явный whitelist
#   - persistence (ipset + iptables-persistent)
#   - CrowdSec (anti-DDoS + community blocklist)
#   - auto-ban cron (вторая линия из БД серверов)
#   - SNI whitelist (через ALLOWED_SNI в .env приложения)
#
# Поддерживает env-переменные для non-interactive запуска:
#   API_ALLOWED_IPS, API_ALLOWED_IPS_V6
#   SSH_ALLOWED_IPS, SSH_ALLOWED_IPS_V6
#   ALLOWED_SNI
#   INSTALL_CROWDSEC=Y|N, INSTALL_AUTOBAN=Y|N
#
# Пример:
#   API_ALLOWED_IPS=1.2.3.4 SSH_ALLOWED_IPS=5.6.7.8 INSTALL_CROWDSEC=Y \
#     INSTALL_AUTOBAN=Y bash ddos.sh

APP_DIR="/opt/haproxy-node"
SERVICE_NAME="haproxy-node"

# ───────────────────────── Colors ─────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ───────────────────────── Root check ─────────────────────
[[ $EUID -eq 0 ]] || err "Run this script as root: sudo bash ddos.sh"

if ! command -v apt-get &>/dev/null; then
  err "This script supports Debian/Ubuntu only"
fi

# ───────────────────────── Read app config ────────────────
# API_PORT, FRONTEND_PORT_MIN/MAX берём из .env приложения — должны быть
# те же, что установил install.sh, иначе firewall пустит трафик не туда.
[ -f "${APP_DIR}/.env" ] || err "${APP_DIR}/.env не найден — сначала запусти install.sh"

API_PORT=$(grep -E '^PORT=' "${APP_DIR}/.env" | head -1 | cut -d= -f2 | tr -d '"' || echo "")
PORT_MIN=$(grep -E '^FRONTEND_PORT_MIN=' "${APP_DIR}/.env" | head -1 | cut -d= -f2 | tr -d '"' || echo "")
PORT_MAX=$(grep -E '^FRONTEND_PORT_MAX=' "${APP_DIR}/.env" | head -1 | cut -d= -f2 | tr -d '"' || echo "")

[ -n "${API_PORT}" ] || err "PORT не найден в ${APP_DIR}/.env"
[ -n "${PORT_MIN}" ] || err "FRONTEND_PORT_MIN не найден в ${APP_DIR}/.env"
[ -n "${PORT_MAX}" ] || err "FRONTEND_PORT_MAX не найден в ${APP_DIR}/.env"

log "Конфиг из .env: API_PORT=${API_PORT}, VLESS=${PORT_MIN}-${PORT_MAX}"

# ───────────────────────── Prompts / env ──────────────────
# Каждая переменная: если задана в env — берём её, иначе спрашиваем.

if [ -z "${API_ALLOWED_IPS+x}" ]; then
  # IPv4, через запятую. Пусто = API доступен только с localhost.
  # Пример: 38.180.122.151,203.0.113.5
  read -rp "IPv4 (через запятую) с доступом к API [пусто = закрыт]: " API_ALLOWED_IPS
fi

if [ -z "${API_ALLOWED_IPS_V6+x}" ]; then
  read -rp "IPv6 (через запятую) с доступом к API [пусто = нет]: " API_ALLOWED_IPS_V6
fi

if [ -z "${SSH_ALLOWED_IPS+x}" ]; then
  # IPv4, через запятую. Пусто = SSH открыт всем (с rate-limit 4/мин).
  read -rp "IPv4 (через запятую) с доступом к SSH :22 [пусто = все + rate-limit]: " SSH_ALLOWED_IPS
fi

if [ -z "${SSH_ALLOWED_IPS_V6+x}" ]; then
  read -rp "IPv6 (через запятую) с доступом к SSH [пусто = все]: " SSH_ALLOWED_IPS_V6
fi

if [ -z "${ALLOWED_SNI+x}" ]; then
  # SNI whitelist — разрешённые имена в TLS ClientHello. Атакующие с чужим SNI
  # или без SNI → reject. Пусто = SNI-фильтр выключен.
  # Пример: www.microsoft.com,yahoo.com,www.apple.com
  read -rp "Разрешённые SNI (через запятую) [пусто = без фильтра]: " ALLOWED_SNI
fi

if [ -z "${INSTALL_CROWDSEC+x}" ]; then
  read -rp "Установить CrowdSec (anti-DDoS + community blocklist)? [Y/n]: " INSTALL_CROWDSEC
fi
INSTALL_CROWDSEC="${INSTALL_CROWDSEC:-Y}"

if [ -z "${INSTALL_AUTOBAN+x}" ]; then
  read -rp "Установить auto-ban cron (каждую минуту)? [Y/n]: " INSTALL_AUTOBAN
fi
INSTALL_AUTOBAN="${INSTALL_AUTOBAN:-Y}"

# Защита от самоблокировки: автоматически добавить текущий SSH IP
# (в IPv4 или IPv6 whitelist — в зависимости от протокола текущей сессии).
# Применяется ТОЛЬКО если соответствующий whitelist не пустой (включён режим whitelist).
CUR_SSH_IP=""
if [ -n "${SSH_CLIENT:-}" ]; then
  CUR_SSH_IP="${SSH_CLIENT%% *}"
elif [ -n "${SSH_CONNECTION:-}" ]; then
  CUR_SSH_IP="${SSH_CONNECTION%% *}"
fi

if [ -n "${CUR_SSH_IP}" ]; then
  if [[ "${CUR_SSH_IP}" == *:* ]]; then
    if [ -n "${SSH_ALLOWED_IPS_V6}" ] && ! echo ",${SSH_ALLOWED_IPS_V6}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv6 SSH в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6},${CUR_SSH_IP}"
    fi
  else
    if [ -n "${SSH_ALLOWED_IPS}" ] && ! echo ",${SSH_ALLOWED_IPS}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv4 SSH в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS},${CUR_SSH_IP}"
    fi
  fi
fi

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
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# Keepalive для долгих VLESS-тоннелей (ловим "мёртвые" коннекты быстрее)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
# BBR congestion control — быстрее TCP для мобильных
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

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

# Per-IP connection limit: 40 одновременных SYN с одного IP.
# 40 = с запасом под VLESS mux (10-20 стримов) + NAT (несколько устройств).
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
  -m connlimit --connlimit-above 40 --connlimit-mask 32 -j DROP

# Global SYN-flood rate limit 500/s с burst 1000.
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
  -m limit --limit 500/s --limit-burst 1000 -j RETURN
iptables -A HAPROXY_DDOS -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j DROP

# ICMP rate limit (keep ping usable but cheap to abuse)
iptables -A HAPROXY_DDOS -p icmp -m limit --limit 5/s --limit-burst 10 -j RETURN
iptables -A HAPROXY_DDOS -p icmp -j DROP

# ───────────────────────── ip6tables filter (DDoS) ────────
IPV6_ENABLED=false
if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  IPV6_ENABLED=true
  log "Setting up ip6tables filter rules (same as IPv4)..."

  ip6tables -D INPUT -j HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -F HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -X HAPROXY_DDOS6 2>/dev/null || true
  ip6tables -N HAPROXY_DDOS6

  ip6tables -A HAPROXY_DDOS6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  ip6tables -A HAPROXY_DDOS6 -m conntrack --ctstate INVALID -j DROP

  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags ALL NONE -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags ALL ALL  -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  ip6tables -A HAPROXY_DDOS6 -p tcp --tcp-flags FIN,RST FIN,RST -j DROP

  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m connlimit --connlimit-above 40 --connlimit-mask 128 -j DROP

  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m limit --limit 500/s --limit-burst 1000 -j RETURN
  ip6tables -A HAPROXY_DDOS6 -p tcp --syn -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j DROP
else
  warn "IPv6 не активен на сервере (ip6tables недоступен) — пропускаю IPv6 защиту"
fi

# ───────────────────────── INPUT Lockdown (policy DROP) ──────
log "Lockdown: rebuilding INPUT chain with policy DROP + explicit whitelist..."

# Policy в ACCEPT — чтобы при переустановке (когда policy уже DROP)
# flush не разорвал SSH между командами
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F INPUT

# Install ipset if missing (понадобится для ЛЮБОГО whitelist: API или SSH)
if { [ -n "${API_ALLOWED_IPS}" ] || [ -n "${API_ALLOWED_IPS_V6}" ] || \
     [ -n "${SSH_ALLOWED_IPS}" ] || [ -n "${SSH_ALLOWED_IPS_V6}" ]; } && \
   ! command -v ipset &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset
fi

# IPv4 API whitelist
if [ -n "${API_ALLOWED_IPS}" ]; then
  log "Configuring IPv4 API whitelist for port ${API_PORT}..."
  ipset create api_whitelist hash:net maxelem 128 2>/dev/null || true
  ipset flush api_whitelist
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
  ipset create ssh_whitelist hash:net maxelem 128 2>/dev/null || true
  ipset flush ssh_whitelist

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
  ipset create ssh_whitelist6 hash:net family inet6 maxelem 128 2>/dev/null || true
  ipset flush ssh_whitelist6

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

# IPv6 API whitelist
if [ "${IPV6_ENABLED}" = "true" ] && [ -n "${API_ALLOWED_IPS_V6}" ]; then
  log "Configuring IPv6 API whitelist for port ${API_PORT}..."
  ipset create api_whitelist6 hash:net family inet6 maxelem 128 2>/dev/null || true
  ipset flush api_whitelist6
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
  iptables -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist src -j ACCEPT
  log "  ACCEPT :22 только для ssh_whitelist"
else
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

# 5. VLESS frontend-диапазон
iptables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

# 6. ICMP с rate-limit
iptables -A INPUT -p icmp -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# 7. ТЕПЕРЬ Policy DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

log "IPv4 INPUT policy DROP активна. Открытые порты: 22 (SSH), ${PORT_MIN}-${PORT_MAX} (VLESS)"
[ -n "${API_ALLOWED_IPS}" ] && log "  + ${API_PORT} (API) — только для api_whitelist"

# ───────────────────────── IPv6 Lockdown (policy DROP) ──────
if [ "${IPV6_ENABLED}" = "true" ]; then
  log "IPv6 lockdown: rebuilding ip6tables INPUT chain with policy DROP..."

  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -F INPUT

  ip6tables -A INPUT -j HAPROXY_DDOS6

  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

  # КРИТИЧНО: ICMPv6 — нужен для Neighbor Discovery, Router Advertisement, PMTU.
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type neighbor-solicitation -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type neighbor-advertisement -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -m limit --limit 5/s -j ACCEPT

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

  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    ip6tables -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist6 src -j ACCEPT
    log "  ACCEPT ${API_PORT}/tcp (v6) для api_whitelist6"
  fi

  ip6tables -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

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
  netfilter-persistent save >/dev/null 2>&1
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  if [ "${IPV6_ENABLED}" = "true" ] && command -v ip6tables-save &>/dev/null; then
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
  fi
fi

# ───────────────────────── SNI whitelist (в .env) ─────────
# Приложение haproxy-node читает ALLOWED_SNI из .env и встраивает в haproxy.cfg
# при следующей регенерации. После записи — рестарт сервиса, чтобы перечитал .env
# и перегенерировал конфиг.
if [ -n "${ALLOWED_SNI}" ]; then
  log "Updating ALLOWED_SNI in ${APP_DIR}/.env..."
  # Удаляем старую строку (если была) и дописываем новую
  sed -i '/^ALLOWED_SNI=/d' "${APP_DIR}/.env"
  echo "ALLOWED_SNI=\"${ALLOWED_SNI}\"" >> "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Restarting ${SERVICE_NAME} to pick up ALLOWED_SNI..."
    systemctl restart "${SERVICE_NAME}" || warn "не удалось перезапустить ${SERVICE_NAME}"
  fi
fi

# ───────────────────────── CrowdSec install ───────────────
if [[ "${INSTALL_CROWDSEC^^}" =~ ^Y ]]; then
  log "Installing CrowdSec (anti-DDoS detector + community blocklist)..."

  if ! command -v cscli &>/dev/null; then
    curl -s https://install.crowdsec.net | sh >/dev/null 2>&1 || warn "CrowdSec repo setup failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq crowdsec >/dev/null || warn "crowdsec install failed"
  fi

  # Firewall bouncer — применяет баны через iptables
  if ! command -v cs-firewall-bouncer &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq crowdsec-firewall-bouncer-iptables >/dev/null 2>&1 || warn "bouncer install failed"
  fi

  if command -v cscli &>/dev/null; then
    log "Installing CrowdSec collections (linux, sshd, haproxy)..."
    cscli hub update >/dev/null 2>&1
    cscli collections install crowdsecurity/linux  >/dev/null 2>&1 || true
    cscli collections install crowdsecurity/sshd   >/dev/null 2>&1 || true
    cscli collections install crowdsecurity/haproxy >/dev/null 2>&1 || true

    # Admin whitelist — статичный, из prompts
    mkdir -p /etc/crowdsec/parsers/s02-enrich
    {
      echo "name: local/admin-whitelist"
      echo "description: \"Admin and trusted IPs (API + SSH + localhost)\""
      echo "whitelist:"
      echo "  reason: \"trusted admin ips\""
      echo "  ip:"
      echo "    - \"127.0.0.1\""
      if [ -n "${API_ALLOWED_IPS}" ]; then
        IFS=',' read -ra _IPS <<< "${API_ALLOWED_IPS//[[:space:]]/}"
        for ip in "${_IPS[@]}"; do
          [ -n "$ip" ] && echo "    - \"$ip\""
        done
      fi
      if [ -n "${SSH_ALLOWED_IPS}" ]; then
        IFS=',' read -ra _IPS <<< "${SSH_ALLOWED_IPS//[[:space:]]/}"
        for ip in "${_IPS[@]}"; do
          [ -n "$ip" ] && echo "    - \"$ip\""
        done
      fi
      if [ -n "${SSH_CLIENT:-}" ]; then
        echo "    - \"${SSH_CLIENT%% *}\""
      fi
    } > /etc/crowdsec/parsers/s02-enrich/whitelist-admin.yaml

    # Backend whitelist — пустой, будет наполняться через NestJS при add/remove server
    cat > /etc/crowdsec/parsers/s02-enrich/whitelist-backend.yaml <<'BEYAML'
name: local/backend-whitelist
description: "Auto-generated by haproxy-node on server add/remove"
whitelist:
  reason: "backend servers (auto)"
  ip:
    - "127.0.0.1"
BEYAML

    systemctl enable --now crowdsec >/dev/null 2>&1
    systemctl enable --now crowdsec-firewall-bouncer >/dev/null 2>&1

    sleep 2
    if systemctl is-active --quiet crowdsec; then
      log "CrowdSec установлен и запущен"
      log "Для подписки на community blocklist: cscli console enroll <KEY>"
      log "Статус: cscli metrics | cscli decisions list"
    else
      warn "CrowdSec установлен, но не стартовал — проверьте: systemctl status crowdsec"
    fi
  else
    warn "cscli не найден после установки — пропускаю настройку CrowdSec"
  fi
fi

# ───────────────────────── auto-ban cron ──────────────────
if [[ "${INSTALL_AUTOBAN^^}" =~ ^Y ]] && [ -f "${APP_DIR}/auto-ban.sh" ]; then
  log "Installing auto-ban cron..."
  cp "${APP_DIR}/auto-ban.sh" /usr/local/bin/auto-ban.sh
  chmod +x /usr/local/bin/auto-ban.sh
  touch /var/log/auto-ban.log
  # `|| true` — защита от случая когда у root нет crontab ещё (первая установка),
  # grep возвращает 1 из-за пустого input, и pipefail останавливает скрипт.
  {
    crontab -l 2>/dev/null | grep -v 'auto-ban.sh' || true
    echo "* * * * * /usr/local/bin/auto-ban.sh >> /var/log/auto-ban.log 2>&1"
  } | crontab - || warn "crontab не удалось обновить — установите вручную"
  log "Auto-ban cron активен (каждую минуту). Логи: /var/log/auto-ban.log"
  log "Статус:  sudo bash /usr/local/bin/auto-ban.sh --stats"
fi

# ───────────────────────── Done ───────────────────────────
log "DDoS protection setup complete!"
echo ""
echo "  Status:"
echo "    iptables -L HAPROXY_DDOS -v -n"
echo "    ipset list api_whitelist"
echo "    ipset list ssh_whitelist"
[[ "${INSTALL_CROWDSEC^^}" =~ ^Y ]] && echo "    cscli metrics ; cscli decisions list"
[[ "${INSTALL_AUTOBAN^^}" =~ ^Y ]] && echo "    bash /usr/local/bin/auto-ban.sh --stats"
echo ""
