#!/usr/bin/env bash
# Закрыть Remna-Node (Xray backend) от всех кроме HAProxy-фронта и Master-сервера.
# SSH остаётся открытым (с rate-limit).
#
# Usage:
#   sudo bash lock-backend.sh HAPROXY_IPV4 [MASTER_IPV4] [HAPROXY_IPV6] [MASTER_IPV6]
#
# Примеры:
#   sudo bash lock-backend.sh 1.2.3.4
#   sudo bash lock-backend.sh 1.2.3.4 38.180.122.151
#   sudo bash lock-backend.sh 1.2.3.4 38.180.122.151 2001:db8::1
#
# Откат:
#   sudo bash lock-backend.sh --revert

set -eu

# ───── Цвета ─────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${G}[+]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
err()  { echo -e "${R}[✗]${NC} $*"; exit 1; }

[ "$EUID" -eq 0 ] || err "Запусти как root: sudo bash $0 ..."

REVERT_FILE="/root/.lock-backend-revert.sh"
SET_V4="backend_whitelist"
SET_V6="backend_whitelist6"

# ═════════ РЕЖИМ ОТКАТА ═════════
if [ "${1:-}" = "--revert" ]; then
  if [ -f "${REVERT_FILE}" ]; then
    log "Откатываю lock-backend..."
    bash "${REVERT_FILE}"
  else
    warn "Файл отката не найден — делаю ручной flush"
    iptables -P INPUT ACCEPT
    iptables -D INPUT -m set ! --match-set ${SET_V4} src -j DROP 2>/dev/null || true
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -m set ! --match-set ${SET_V6} src -j DROP 2>/dev/null || true
    ipset destroy ${SET_V4} 2>/dev/null || true
    ipset destroy ${SET_V6} 2>/dev/null || true
  fi
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null
  log "Готово. Сервер снова принимает все коннекты."
  exit 0
fi

# ═════════ ПАРСИНГ АРГУМЕНТОВ ═════════
HAPROXY_V4="${1:-}"
MASTER_V4="${2:-}"
HAPROXY_V6="${3:-}"
MASTER_V6="${4:-}"

[ -n "${HAPROXY_V4}" ] || err "Требуется IPv4 HAProxy-фронта. Usage: $0 HAPROXY_IPV4 [MASTER_IPV4] [HAPROXY_IPV6] [MASTER_IPV6]"

# ═════════ ОПРЕДЕЛИТЬ ТЕКУЩИЙ SSH IP (защита от самоблока) ═════════
CUR_SSH=""
if [ -n "${SSH_CLIENT:-}" ]; then
  CUR_SSH="${SSH_CLIENT%% *}"
elif [ -n "${SSH_CONNECTION:-}" ]; then
  CUR_SSH="${SSH_CONNECTION%% *}"
fi

log "HAProxy IPv4:   ${HAPROXY_V4}"
[ -n "${MASTER_V4}" ] && log "Master IPv4:    ${MASTER_V4}"
[ -n "${HAPROXY_V6}" ] && log "HAProxy IPv6:   ${HAPROXY_V6}"
[ -n "${MASTER_V6}" ] && log "Master IPv6:    ${MASTER_V6}"
[ -n "${CUR_SSH}" ] && log "Текущий SSH IP: ${CUR_SSH} (будет добавлен)"

# ═════════ ПРОВЕРКИ И УСТАНОВКА ═════════
command -v ipset >/dev/null || { log "Устанавливаю ipset..."; apt-get install -y -qq ipset; }
command -v iptables-save >/dev/null || apt-get install -y -qq iptables

# ═════════ СОХРАНИТЬ ТЕКУЩИЕ ПРАВИЛА ДЛЯ ОТКАТА ═════════
log "Сохраняю текущие правила для возможного отката..."
iptables-save   > /tmp/iptables.before.rules
ip6tables-save  > /tmp/ip6tables.before.rules 2>/dev/null || true

cat > "${REVERT_FILE}" <<REVERT
#!/usr/bin/env bash
set -e
iptables-restore < /tmp/iptables.before.rules 2>/dev/null || iptables -F
ip6tables-restore < /tmp/ip6tables.before.rules 2>/dev/null || ip6tables -F 2>/dev/null || true
ipset destroy ${SET_V4} 2>/dev/null || true
ipset destroy ${SET_V6} 2>/dev/null || true
iptables -P INPUT ACCEPT
ip6tables -P INPUT ACCEPT 2>/dev/null || true
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null
echo "[+] Откат выполнен."
REVERT
chmod +x "${REVERT_FILE}"
log "Скрипт отката: ${REVERT_FILE}"

# ═════════ СОЗДАТЬ IPSET'Ы ═════════
log "Создаю whitelist ipset..."
ipset destroy ${SET_V4} 2>/dev/null || true
ipset create ${SET_V4} hash:net maxelem 128

ipset add ${SET_V4} "${HAPROXY_V4}"
[ -n "${MASTER_V4}" ] && ipset add ${SET_V4} "${MASTER_V4}"
[ -n "${CUR_SSH}" ] && [[ "${CUR_SSH}" != *:* ]] && ipset add ${SET_V4} "${CUR_SSH}" 2>/dev/null || true

# IPv6
if [ -n "${HAPROXY_V6}" ] || [ -n "${MASTER_V6}" ] || [[ "${CUR_SSH:-}" == *:* ]]; then
  ipset destroy ${SET_V6} 2>/dev/null || true
  ipset create ${SET_V6} hash:net family inet6 maxelem 128
  [ -n "${HAPROXY_V6}" ] && ipset add ${SET_V6} "${HAPROXY_V6}"
  [ -n "${MASTER_V6}" ]  && ipset add ${SET_V6} "${MASTER_V6}"
  [[ "${CUR_SSH:-}" == *:* ]] && ipset add ${SET_V6} "${CUR_SSH}" 2>/dev/null || true
fi

# ═════════ ПРАВИЛА IPV4 ═════════
log "Применяю iptables-правила (IPv4)..."

# Временно ACCEPT чтобы не разорвать SSH между командами
iptables -P INPUT ACCEPT

# Flush и заново
iptables -F INPUT

# 1. loopback
iptables -A INPUT -i lo -j ACCEPT

# 2. Established (сохраняет текущий SSH и живые прокси-сессии)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 3. SSH (rate-limit против brute-force)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
  -m recent --set --name SSH --rsource
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
  -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 4. Whitelist — трафик с доверенных IP (HAProxy, Master) принимается полностью
iptables -A INPUT -m set --match-set ${SET_V4} src -j ACCEPT

# 5. ICMP с rate-limit (ping диагностика)
iptables -A INPUT -p icmp -m limit --limit 5/s -j ACCEPT

# 6. Всё остальное — DROP по policy
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# ═════════ ПРАВИЛА IPV6 ═════════
if command -v ip6tables >/dev/null 2>&1; then
  log "Применяю ip6tables-правила (IPv6)..."
  ip6tables -P INPUT ACCEPT
  ip6tables -F INPUT

  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

  # ICMPv6 — ОБЯЗАТЕЛЬНО разрешить (neighbor discovery, MTU, etc)
  ip6tables -A INPUT -p icmpv6 -j ACCEPT

  # SSH (на случай если коннектитесь по IPv6)
  ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

  # Whitelist IPv6
  if ipset list -n 2>/dev/null | grep -q "^${SET_V6}$"; then
    ip6tables -A INPUT -m set --match-set ${SET_V6} src -j ACCEPT
  fi

  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT
fi

# ═════════ СОХРАНИТЬ ═════════
log "Сохраняю правила..."
ipset save > /etc/ipset.conf

# Восстановление ipset при старте системы
if [ ! -f /etc/network/if-pre-up.d/ipset-restore ]; then
  cat > /etc/network/if-pre-up.d/ipset-restore <<'EOF'
#!/bin/sh
[ -f /etc/ipset.conf ] && /sbin/ipset restore < /etc/ipset.conf
exit 0
EOF
  chmod +x /etc/network/if-pre-up.d/ipset-restore
fi

if command -v netfilter-persistent >/dev/null; then
  netfilter-persistent save >/dev/null
  log "Правила сохранены через netfilter-persistent"
else
  apt-get install -y -qq iptables-persistent 2>/dev/null
  netfilter-persistent save >/dev/null 2>&1 || {
    mkdir -p /etc/iptables
    iptables-save   > /etc/iptables/rules.v4
    ip6tables-save  > /etc/iptables/rules.v6 2>/dev/null || true
  }
fi

# ═════════ СТАТИСТИКА ═════════
echo
echo "═══ Whitelist IPv4 ═══"
ipset list ${SET_V4} | tail -n +9 | head -10
if ipset list -n 2>/dev/null | grep -q "^${SET_V6}$"; then
  echo
  echo "═══ Whitelist IPv6 ═══"
  ipset list ${SET_V6} | tail -n +9 | head -10
fi

echo
echo "═══ Правила INPUT (IPv4) ═══"
iptables -L INPUT -nv --line-numbers | head -15

echo
log "Готово. Backend закрыт от всех кроме whitelist + SSH."
log "Проверьте что всё работает:"
echo "    docker logs remnanode --tail 20     # нет ошибок подключения к мастеру"
echo "    curl -I http://<HAPROXY_IP>:<PORT>  # с haproxy-фронта — должен работать VLESS"
echo
log "Откат: sudo bash $0 --revert"
