#!/usr/bin/env bash
# Проверка доступности всех backend-серверов с xray.
#
# Что делает для каждого backend'а из /servers:
#   1. TCP handshake (nc -zv)
#   2. TLS handshake (openssl s_client) — xray обычно слушает TLS
#   3. HAProxy backend status (через stats socket если доступен)
#   4. Свежесть логов HAProxy (коннекты идут или нет)
#
# Usage: sudo bash check-backends.sh

set +e

if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
else
  R=''; G=''; Y=''; B=''; NC=''
fi
hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
ok()   { echo -e "${G}✓${NC} $*"; }
warn() { echo -e "${Y}⚠${NC} $*"; }
bad()  { echo -e "${R}✗${NC} $*"; }

[ "$EUID" -eq 0 ] || { bad "Запусти через sudo"; exit 1; }

# ───── Конфиг из .env ─────
ENV_FILE="/opt/haproxy-node/.env"
if [ ! -f "${ENV_FILE}" ]; then
  bad "${ENV_FILE} не найден"; exit 1
fi
API_PORT=$(awk -F= '/^PORT=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
API_KEY=$(awk -F= '/^API_KEY=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
API_PORT="${API_PORT:-3000}"

# Установим зависимости если нет
for tool in jq nc openssl; do
  if ! command -v "${tool}" >/dev/null; then
    apt-get install -y -qq "${tool}" >/dev/null 2>&1 || \
      apt-get install -y -qq "$([ "$tool" = "nc" ] && echo netcat-openbsd || echo "$tool")" >/dev/null 2>&1
  fi
done

# ───── Получить список серверов ─────
hdr "Получение списка backend'ов"
SERVERS=$(curl -sf --max-time 5 -H "x-api-key: ${API_KEY}" \
  "http://127.0.0.1:${API_PORT}/servers" 2>/dev/null)

if [ -z "${SERVERS}" ] || ! echo "${SERVERS}" | jq -e . >/dev/null 2>&1; then
  bad "Не удалось получить /servers — API не отвечает или API_KEY неверный"
  exit 1
fi

COUNT=$(echo "${SERVERS}" | jq 'length')
if [ "${COUNT}" = "0" ]; then
  warn "В БД нет backend-серверов — HAProxy не форвардит никуда"
  echo "Добавить можно через: curl -X POST http://127.0.0.1:${API_PORT}/servers \\"
  echo "   -H 'x-api-key: \$API_KEY' -H 'Content-Type: application/json' \\"
  echo "   -d '{\"ip\":\"<backend-ip>\",\"backendPort\":8443}'"
  exit 0
fi

ok "Найдено серверов: ${COUNT}"

# ───── HAProxy stats socket (если включён) ─────
HAPROXY_STATS=""
for sock in /var/run/haproxy/admin.sock /run/haproxy/admin.sock /var/lib/haproxy/stats.sock; do
  if [ -S "${sock}" ]; then
    HAPROXY_STATS="${sock}"
    break
  fi
done

if [ -n "${HAPROXY_STATS}" ] && command -v socat >/dev/null; then
  STATS=$(echo "show stat" | socat stdio "${HAPROXY_STATS}" 2>/dev/null)
else
  STATS=""
fi

# ───── Пройтись по каждому серверу ─────
ALIVE=0
DEAD=0

for i in $(seq 0 $((COUNT-1))); do
  NAME=$(echo "${SERVERS}"     | jq -r ".[${i}].name")
  IP=$(echo "${SERVERS}"       | jq -r ".[${i}].ip")
  BPORT=$(echo "${SERVERS}"    | jq -r ".[${i}].backendPort")
  FPORT=$(echo "${SERVERS}"    | jq -r ".[${i}].frontendPort")

  hdr "${NAME} — ${IP}:${BPORT} (frontend :${FPORT})"

  # 1. TCP handshake
  if timeout 3 bash -c "echo | nc -w 2 ${IP} ${BPORT}" >/dev/null 2>&1; then
    ok "TCP handshake → доступен"
    TCP_OK=1
  else
    bad "TCP handshake → НЕДОСТУПЕН (timeout или connection refused)"
    TCP_OK=0
  fi

  # 2. TLS handshake (xray с reality слушает TLS)
  if [ "${TCP_OK}" = "1" ]; then
    TLS_OUT=$(timeout 4 openssl s_client -connect "${IP}:${BPORT}" -servername "www.google.com" \
      -verify_quiet -brief </dev/null 2>&1)
    if echo "${TLS_OUT}" | grep -qE "Protocol *:|CONNECTION ESTABLISHED|subject="; then
      ok "TLS handshake → отвечает"
      # Выдернуть subject/issuer чтобы видеть что за сертификат отдаёт xray
      SUBJ=$(echo "${TLS_OUT}" | grep -oE "subject=[^$]*" | head -1)
      [ -n "${SUBJ}" ] && echo "   ${SUBJ}"
    else
      warn "TLS handshake не удался — возможно xray не в TLS-режиме"
      echo "   (фрагмент ошибки: $(echo "${TLS_OUT}" | tr '\n' ' ' | head -c 120))"
    fi
  fi

  # 3. HAProxy status (из stats socket)
  if [ -n "${STATS}" ]; then
    HA_STATUS=$(echo "${STATS}" | awk -F, -v pxname="${NAME}" '$1==pxname && $2!="BACKEND" && $2!="FRONTEND" {print $18}')
    if [ -n "${HA_STATUS}" ]; then
      if [ "${HA_STATUS}" = "UP" ]; then
        ok "HAProxy health-check: UP"
      else
        bad "HAProxy health-check: ${HA_STATUS} (ожидается UP)"
      fi
      # Детали: last check result + last change
      LAST_CHK=$(echo "${STATS}" | awk -F, -v pxname="${NAME}" '$1==pxname && $2!="BACKEND" && $2!="FRONTEND" {print $64}')
      [ -n "${LAST_CHK}" ] && echo "   last check: ${LAST_CHK}"
    fi
  fi

  # 4. Свежие коннекты на этом frontend через HAProxy (из логов)
  RECENT_LOG=$(sudo journalctl -u haproxy --since "1 min ago" --no-pager 2>/dev/null | \
    grep -c "${NAME}_in" 2>/dev/null || echo 0)
  RECENT_LOG=${RECENT_LOG:-0}
  if [ "${RECENT_LOG}" -gt 0 ] 2>/dev/null; then
    ok "HAProxy-логи за 1 мин: ${RECENT_LOG} коннектов → живые клиенты идут"
  else
    warn "HAProxy-логи за 1 мин: 0 коннектов на ${NAME}_in (никто не подключается или логи выключены)"
  fi

  if [ "${TCP_OK}" = "1" ]; then
    ALIVE=$((ALIVE+1))
  else
    DEAD=$((DEAD+1))
  fi
done

# ───── Итог ─────
hdr "ИТОГ"
echo "   живых backend'ов: ${ALIVE} / ${COUNT}"
if [ "${DEAD}" -gt 0 ]; then
  bad "мёртвых: ${DEAD}"
  echo
  echo "Если backend мёртвый:"
  echo "  • Зайди на backend-сервер (например по ssh), проверь xray:"
  echo "    systemctl status xray  (или docker ps | grep xray)"
  echo "  • Проверь на backend'е firewall — пропускает ли он HAProxy-ноду:"
  echo "    iptables -L INPUT -nv | grep <backend-port>"
  echo "  • Если у тебя xray-backend-lockdown.sh на backend'е —"
  echo "    убедись что IP этой HAProxy-ноды в whitelist backend'а"
fi

if [ -z "${HAPROXY_STATS}" ]; then
  echo
  warn "HAProxy stats socket не найден (проверены /var/run/haproxy/admin.sock, /run/haproxy/admin.sock)"
  echo "Чтобы видеть health-check status, добавь в /etc/haproxy/haproxy.cfg в секцию global:"
  echo "   stats socket /run/haproxy/admin.sock mode 660 level admin"
  echo "и перезапусти HAProxy."
fi
