#!/usr/bin/env bash
# Проверка: попадает ли указанный IP под текущий whitelist + может ли
# TCP-подключиться к VLESS-портам сервера.
#
# Usage:
#   sudo bash check-my-ip.sh <IP>                    # проверить + тестовый connect
#   sudo bash check-my-ip.sh <IP> --add              # проверить и сразу добавить если нет
#   sudo bash check-my-ip.sh $(curl -s ifconfig.me)  # проверить свой external IP
#
# Почему важен ipset test (а не grep по ipset list):
#   IP может не быть в set'е как точный /32, но может матчиться CIDR-диапазоном
#   (например 213.242.35.242 матчится 213.242.35.0/24). ipset test корректно
#   учитывает trie hash:net.

set +e

# ───── Colors ─────
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
else
  R=''; G=''; Y=''; B=''; NC=''
fi
hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
ok()   { echo -e "${G}✓ $*${NC}"; }
warn() { echo -e "${Y}⚠ $*${NC}"; }
crit() { echo -e "${R}🔴 $*${NC}"; }

[ "$EUID" -eq 0 ] || { crit "Запусти как root: sudo bash $0"; exit 1; }

IP="${1:-}"
if [ -z "${IP}" ]; then
  echo "Usage: sudo bash $0 <IP> [--add]"
  echo "  sudo bash $0 213.242.35.242"
  echo "  sudo bash $0 \$(curl -s ifconfig.me) --add"
  exit 1
fi

MODE="${2:-}"
SET="vless_lockdown"

# ───── Конфигурация из .env ─────
ENV_FILE="/opt/haproxy-node/.env"
if [ -f "${ENV_FILE}" ]; then
  PORT_MIN=$(awk -F= '/^FRONTEND_PORT_MIN=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
  PORT_MAX=$(awk -F= '/^FRONTEND_PORT_MAX=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
  API_PORT=$(awk -F= '/^PORT=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
  API_KEY=$(awk -F= '/^API_KEY=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
fi
PORT_MIN="${PORT_MIN:-10000}"
PORT_MAX="${PORT_MAX:-65000}"
API_PORT="${API_PORT:-3000}"

echo -e "${B}Проверка IP: ${IP}${NC}"
echo "  VLESS ports: ${PORT_MIN}:${PORT_MAX}"
echo "  Ipset:       ${SET}"

# ═══════════════════════════════════════════════════════════
# 1. Валидация IP
# ═══════════════════════════════════════════════════════════
if ! echo "${IP}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  crit "'${IP}' не похож на IPv4 адрес"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# 2. ipset test — матчится ли IP под whitelist (включая CIDR)
# ═══════════════════════════════════════════════════════════
hdr "1. IP в whitelist?"
if ! ipset list -t "${SET}" >/dev/null 2>&1; then
  crit "ipset '${SET}' не существует — создай через install.sh или LockdownService"
  exit 1
fi

# ipset test возвращает 0 если IP матчится (точный или CIDR), 1 если нет
if ipset test "${SET}" "${IP}" 2>/dev/null; then
  ok "IP ${IP} МАТЧИТСЯ whitelist (точный /32 или под CIDR)"
  MATCH=1
else
  crit "IP ${IP} НЕ в whitelist"
  MATCH=0
fi

# Если /32 записи нет, но есть матч — показать какой CIDR захватывает
if [ "${MATCH}" = "1" ]; then
  # Проверим был ли это точный /32
  if ipset list "${SET}" 2>/dev/null | grep -qxF "${IP}"; then
    echo "   → точный /32 в ipset"
  else
    echo "   → матчится через CIDR-диапазон (найти какой):"
    # Перебираем /24, /16, /8 и т. д.
    OCT=( $(echo "${IP}" | tr '.' ' ') )
    for mask in 32 28 27 26 25 24 23 22 21 20 19 18 17 16 8; do
      # Построить network-boundary для данной маски
      case $mask in
        32) test_cidr="${IP}/32" ;;
        24) test_cidr="${OCT[0]}.${OCT[1]}.${OCT[2]}.0/24" ;;
        16) test_cidr="${OCT[0]}.${OCT[1]}.0.0/16" ;;
        8)  test_cidr="${OCT[0]}.0.0.0/8" ;;
        *)  continue ;;
      esac
      if ipset list "${SET}" 2>/dev/null | grep -qxF "${test_cidr}"; then
        echo "     ${test_cidr}"
      fi
    done
  fi
fi

# ═══════════════════════════════════════════════════════════
# 3. --add — добавить в whitelist через API
# ═══════════════════════════════════════════════════════════
if [ "${MODE}" = "--add" ] && [ "${MATCH}" = "0" ]; then
  hdr "2. Добавляю ${IP} в whitelist через API"

  if [ -z "${API_KEY}" ]; then
    crit "API_KEY не найден в ${ENV_FILE}"
    exit 1
  fi

  RESP=$(curl -sf --max-time 5 -X POST \
    "http://127.0.0.1:${API_PORT}/lockdown/ips/add" \
    -H "x-api-key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"ips\":[\"${IP}\"]}" 2>&1)

  if echo "${RESP}" | grep -q '"added"'; then
    ok "Добавлено: ${RESP}"
    # Перепроверим
    if ipset test "${SET}" "${IP}" 2>/dev/null; then
      ok "Подтверждено: ipset test проходит"
      MATCH=1
    else
      crit "После POST ipset test всё равно не находит — проверь логи сервиса"
    fi
  else
    crit "Ошибка API: ${RESP}"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 4. Тестовая TCP-проверка: дропается ли SYN с этого IP?
# ═══════════════════════════════════════════════════════════
hdr "3. Живая проверка iptables-счётчиков"
# Смотрим delta match-set счётчика (что этот IP попал бы через whitelist)
# и delta policy-DROP (что дропнулся бы если бы не whitelist)
BEFORE_MATCH=$(iptables -L INPUT -n -v -x 2>/dev/null \
  | awk -v s="${SET}" '/match-set/ && index($0, s) {print $1; exit}')
BEFORE_POLICY_DROP=$(iptables -L INPUT -n -v -x 2>/dev/null \
  | awk '/^Chain INPUT/ {match($0, /[0-9]+ packets/); print substr($0, RSTART, RLENGTH-8)}' \
  | tr -d ' ')

echo "   match-set ACCEPT счётчик (пакетов): ${BEFORE_MATCH}"

# ═══════════════════════════════════════════════════════════
# 5. Выбрать активный VLESS frontend-порт для теста
# ═══════════════════════════════════════════════════════════
hdr "4. Активные VLESS frontend-порты"
ACTIVE_PORTS=$(ss -tln 2>/dev/null \
  | awk -v pmin="${PORT_MIN}" -v pmax="${PORT_MAX}" '
    NR>1 {
      n = split($4, a, ":"); p = a[n]+0;
      if (p >= pmin && p <= pmax) print p
    }' | sort -u)

if [ -z "${ACTIVE_PORTS}" ]; then
  warn "HAProxy не слушает ни один порт в ${PORT_MIN}:${PORT_MAX}"
  warn "  Проверь: systemctl status haproxy; sudo ss -tlnp | grep haproxy"
  warn "  Или: curl -H 'x-api-key: \${API_KEY}' http://127.0.0.1:${API_PORT}/servers"
  warn "  (если нет серверов → HAProxy не настроен на VLESS-порты)"
else
  echo "${ACTIVE_PORTS}" | sed 's/^/   :/'
  FIRST_PORT=$(echo "${ACTIVE_PORTS}" | head -1)

  # ─── Локальный TCP-тест через loopback ───
  hdr "5. TCP handshake test (127.0.0.1:${FIRST_PORT})"
  # Не триггерит firewall на внешнем IP, но проверяет что HAProxy слушает
  if command -v nc >/dev/null; then
    timeout 3 bash -c "echo | nc -w 2 127.0.0.1 ${FIRST_PORT}" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      ok "HAProxy отвечает на loopback — TCP-стек работает"
    else
      warn "nc не смог подключиться даже по loopback — HAProxy упал?"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════
# 6. Советы по дебагу
# ═══════════════════════════════════════════════════════════
hdr "ВЕРДИКТ"

if [ "${MATCH}" = "1" ]; then
  ok "IP ${IP} пройдёт iptables-фильтр"
  echo
  echo "Если клиент с этого IP всё ещё НЕ может подключиться:"
  echo "  1. HAProxy не слушает нужный порт:"
  echo "     ss -tlnp | grep haproxy"
  echo "  2. Клиент ходит через IPv6 (v6 не защищён lockdown'ом но и не открыт):"
  echo "     у клиента: curl -4 <server-ip>:${FIRST_PORT:-10000}  # форсить IPv4"
  echo "  3. Xray backend упал (сервер в БД есть, но target:port недоступен):"
  echo "     curl -sH 'x-api-key: \$API_KEY' http://127.0.0.1:${API_PORT}/servers"
  echo "  4. Клиент подключается на НЕ тот порт:"
  echo "     активные VLESS-порты на сервере: ${ACTIVE_PORTS:-нет}"
  echo "  5. Провайдер блокирует исходящие на нестандартный порт (встречается с mobile)"
else
  crit "IP ${IP} БУДЕТ ДРОПНУТ policy DROP"
  echo
  echo "Что делать:"
  echo "  # Быстрый добавить через API"
  echo "  curl -X POST http://127.0.0.1:${API_PORT}/lockdown/ips/add \\"
  echo "    -H 'x-api-key: \$API_KEY' -H 'Content-Type: application/json' \\"
  echo "    -d '{\"ips\":[\"${IP}\"]}'"
  echo
  echo "  # Или повторный запуск этого скрипта с --add:"
  echo "  sudo bash $0 ${IP} --add"
fi
