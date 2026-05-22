#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════
#  Lockdown для сервера с Xray (backend-нода Remnawave)
#  Разрешает входящий трафик только с указанных IP
#  Не трогает OUTPUT и FORWARD (Docker продолжает работать)
#
#  Использование:
#    1. Впишите свои IP в массив IPS_V4 ниже
#    2. Запустите:   sudo bash xray-backend-lockdown.sh
#    3. Проверьте:   iptables -L INPUT -nv
#
#  Откат (если потеряли доступ — через консоль хостера):
#    sudo bash xray-backend-lockdown.sh --revert
# ═════════════════════════════════════════════════════════════════

set -eu

# ═══════════════════════════════════════════════════════════════
#  🔧 КОНФИГУРАЦИЯ — впишите сюда свои IP
# ═══════════════════════════════════════════════════════════════

# IPv4 — кому разрешён доступ к backend'у
IPS_V4=(
  "172.86.93.10"        # ← IP HAProxy-фронта (входящий сервер)
  "38.180.122.151"      # ← IP панели Remnawave (master)
  # Ваш SSH IP добавится автоматически из $SSH_CLIENT,
  # но лучше вписать явно на случай смены IP:
  # "107.189.26.23"
)

# IPv6 — опционально (если используете)
IPS_V6=(
  # "2a00:1450:4010::/48"   # пример
)

# Разрешить ICMP (ping для диагностики)
ALLOW_ICMP=true

# ═══════════════════════════════════════════════════════════════
#  ⚙️ ДАЛЬШЕ НЕ РЕДАКТИРОВАТЬ
# ═══════════════════════════════════════════════════════════════

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${G}[+]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
err()  { echo -e "${R}[✗]${NC} $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || err "Запусти как root: sudo bash $0"

REVERT_FILE="/root/.xray-backend-revert.iptables"
REVERT_FILE_V6="/root/.xray-backend-revert.ip6tables"

# ═════════════════════════════════════════════════════════════════
#  РЕЖИМ ОТКАТА
# ═════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--revert" ]; then
  log "Откат iptables к предыдущему состоянию..."
  if [ -f "$REVERT_FILE" ]; then
    iptables-restore < "$REVERT_FILE"
    log "IPv4 восстановлен"
  else
    warn "Нет backup'а, делаю полный reset: INPUT ACCEPT, flush"
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F INPUT
  fi

  if [ -f "$REVERT_FILE_V6" ] && command -v ip6tables &>/dev/null; then
    ip6tables-restore < "$REVERT_FILE_V6"
    log "IPv6 восстановлен"
  fi

  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null
  log "Готово — сервер снова открыт"
  exit 0
fi

# ═════════════════════════════════════════════════════════════════
#  АВТОДОБАВЛЕНИЕ ТЕКУЩЕГО SSH IP (защита от самоблокировки)
# ═════════════════════════════════════════════════════════════════
# Helper: членство $1 в массиве, имя которого передано как $2.
# Безопаснее `[[ " ${arr[*]:-} " =~ " $val " ]]` — последнее ломается на
# пустом массиве + set -u и false-positive для подстрок (192.168.1.1
# матчится в "192.168.1.10").
in_array() {
  local needle="$1"
  local -n arr_ref="$2"
  local item
  for item in "${arr_ref[@]:-}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

if [ -n "${SSH_CLIENT:-}" ]; then
  CUR="${SSH_CLIENT%% *}"
  if [[ "$CUR" == *:* ]]; then
    # IPv6
    if ! in_array "$CUR" IPS_V6; then
      IPS_V6+=("$CUR")
      log "Auto-added IPv6 SSH: $CUR"
    fi
  else
    # IPv4
    if ! in_array "$CUR" IPS_V4; then
      IPS_V4+=("$CUR")
      log "Auto-added IPv4 SSH: $CUR"
    fi
  fi
fi

# Защита — не запускать с пустым whitelist (отрежет SSH)
if [ "${#IPS_V4[@]}" -eq 0 ]; then
  err "IPS_V4 пустой! Впишите хотя бы один IP, иначе потеряете SSH"
fi

# ═════════════════════════════════════════════════════════════════
#  УСТАНОВКА ЗАВИСИМОСТЕЙ
# ═════════════════════════════════════════════════════════════════
command -v iptables-save >/dev/null || apt-get install -y -qq iptables
if ! command -v netfilter-persistent >/dev/null; then
  log "Устанавливаю iptables-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null
fi

# ═════════════════════════════════════════════════════════════════
#  BACKUP ТЕКУЩИХ ПРАВИЛ (для возможного отката)
# ═════════════════════════════════════════════════════════════════
log "Сохраняю backup в $REVERT_FILE..."
iptables-save > "$REVERT_FILE"
if command -v ip6tables &>/dev/null; then
  ip6tables-save > "$REVERT_FILE_V6" 2>/dev/null || true
fi

# ═════════════════════════════════════════════════════════════════
#  IPv4 LOCKDOWN
# ═════════════════════════════════════════════════════════════════
log "Применяю IPv4 whitelist..."

# ВАЖНО: сначала policy ACCEPT, потом flush — не разорвём SSH при переустановке
iptables -P INPUT ACCEPT
iptables -F INPUT

# 1. Loopback + ESTABLISHED + INVALID
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 2. Whitelist IPv4
for ip in "${IPS_V4[@]}"; do
  iptables -A INPUT -s "$ip" -j ACCEPT
  log "  + allow IPv4: $ip"
done

# 3. ICMP (опционально)
if [ "$ALLOW_ICMP" = "true" ]; then
  iptables -A INPUT -p icmp -m limit --limit 5/s -j ACCEPT
fi

# 4. Policy DROP — всё остальное в чёрную дыру
iptables -P INPUT DROP

# ПРИМЕЧАНИЕ: FORWARD и OUTPUT НЕ ТРОГАЕМ!
# FORWARD нужен Docker (Remnawave-контейнер через docker0 bridge)
# OUTPUT — нужен Xray для подключения к Google/Meta/TG

# ═════════════════════════════════════════════════════════════════
#  IPv6 LOCKDOWN (если доступен)
# ═════════════════════════════════════════════════════════════════
if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  log "Применяю IPv6 whitelist..."

  ip6tables -P INPUT ACCEPT
  ip6tables -F INPUT

  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

  # ICMPv6 — ОБЯЗАТЕЛЬНО разрешить (NDP/RA — иначе сеть сломается)
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

  for ip in "${IPS_V6[@]:-}"; do
    [ -z "$ip" ] && continue
    ip6tables -A INPUT -s "$ip" -j ACCEPT
    log "  + allow IPv6: $ip"
  done

  ip6tables -P INPUT DROP
  # FORWARD и OUTPUT не трогаем
fi

# ═════════════════════════════════════════════════════════════════
#  PERSISTENCE — сохранить навсегда
# ═════════════════════════════════════════════════════════════════
netfilter-persistent save >/dev/null
log "Правила сохранены (переживут reboot)"

# ═════════════════════════════════════════════════════════════════
#  РЕЗУЛЬТАТ
# ═════════════════════════════════════════════════════════════════
echo
log "═══════════════════════════════════════════"
log "🔒 Backend заблокирован"
log "Разрешённые IPv4:"
for ip in "${IPS_V4[@]}"; do
  echo "    • $ip"
done
if [ "${#IPS_V6[@]:-0}" -gt 0 ]; then
  log "Разрешённые IPv6:"
  for ip in "${IPS_V6[@]}"; do
    [ -n "$ip" ] && echo "    • $ip"
  done
fi
log "═══════════════════════════════════════════"

echo
echo "═══ IPv4 INPUT правила ═══"
iptables -L INPUT -nv --line-numbers | head -15

if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  echo
  echo "═══ IPv6 INPUT правила ═══"
  ip6tables -L INPUT -nv --line-numbers 2>/dev/null | head -12
fi

echo
log "Откат если что-то сломалось: sudo bash $0 --revert"
