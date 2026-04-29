#!/usr/bin/env bash
# TL;DR-проверка: всё ли готово принимать коннекты от whitelist'а?
# Запуск: sudo bash quick-check.sh

set +e

if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
else
  R=''; G=''; Y=''; NC=''
fi
ok()   { echo -e "${G}✓${NC} $*"; }
bad()  { echo -e "${R}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "${Y}⚠${NC} $*"; }

FAIL=0

[ "$EUID" -eq 0 ] || { bad "Запусти через sudo"; exit 1; }

ENV_FILE="/opt/haproxy-node/.env"
PORT_MIN=$(awk -F= '/^FRONTEND_PORT_MIN=/ {gsub(/"/,""); print $2}' "${ENV_FILE}" 2>/dev/null)
PORT_MAX=$(awk -F= '/^FRONTEND_PORT_MAX=/ {gsub(/"/,""); print $2}' "${ENV_FILE}" 2>/dev/null)
API_PORT=$(awk -F= '/^PORT=/ {gsub(/"/,""); print $2}' "${ENV_FILE}" 2>/dev/null)
API_KEY=$(awk -F= '/^API_KEY=/ {gsub(/"/,""); print $2}' "${ENV_FILE}" 2>/dev/null)
PORT_MIN="${PORT_MIN:-10000}"
PORT_MAX="${PORT_MAX:-65000}"
API_PORT="${API_PORT:-3000}"

echo "── haproxy-node quick check ──"

# 1. INPUT policy
POL=$(iptables -L INPUT -n 2>/dev/null | awk '/^Chain INPUT/ {gsub(/[)(]/,""); print $4}')
[ "$POL" = "DROP" ] && ok "INPUT policy: DROP" || bad "INPUT policy: $POL (должно быть DROP)"

# 2. match-set правило
if iptables -C INPUT -p tcp -m multiport --dports "${PORT_MIN}:${PORT_MAX}" \
     -m set --match-set vless_lockdown src -j ACCEPT 2>/dev/null; then
  ok "match-set правило активно (${PORT_MIN}:${PORT_MAX} → vless_lockdown)"
else
  bad "match-set правило НЕ установлено — lockdown выключен"
fi

# 3. ipset
TYPE=$(ipset list -t vless_lockdown 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}')
SIZE=$(ipset list -t vless_lockdown 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; exit}')
if [ "$TYPE" = "hash:net" ] && [ "${SIZE:-0}" -gt 0 ]; then
  ok "ipset vless_lockdown: hash:net, ${SIZE} записей"
elif [ -z "$TYPE" ]; then
  bad "ipset vless_lockdown не существует"
else
  bad "ipset vless_lockdown: тип=${TYPE}, записей=${SIZE:-0}"
fi

# 4. loopback + established (без них весь сервер отвалится)
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null \
  && ok "loopback ACCEPT есть" \
  || bad "loopback ACCEPT нет — сломает API-запросы с localhost"

iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  && ok "ESTABLISHED ACCEPT есть" \
  || bad "ESTABLISHED ACCEPT нет — даже исходящие соединения сервера отвалятся"

# 5. SSH (иначе ты сам себя запер)
if iptables -S INPUT 2>/dev/null | grep -qE "dport 22.*ACCEPT|--dport 22"; then
  ok "SSH :22 правило есть"
else
  warn "нет явного ACCEPT на :22 (проверь что SSH не отвалится)"
fi

# 6. HAProxy слушает VLESS-порты?
LISTEN=$(ss -tln 2>/dev/null | awk -v pmin="${PORT_MIN}" -v pmax="${PORT_MAX}" '
  NR>1 { n=split($4,a,":"); p=a[n]+0; if (p>=pmin && p<=pmax) print p }
' | sort -u | tr '\n' ' ')
if [ -n "$LISTEN" ]; then
  ok "HAProxy слушает порты: ${LISTEN}"
else
  bad "HAProxy не слушает ни один VLESS-порт (серверов в БД нет? HAProxy упал?)"
fi

# 7. API работает?
STATUS=$(curl -sf --max-time 3 -H "x-api-key: ${API_KEY}" \
  "http://127.0.0.1:${API_PORT}/lockdown/status" 2>/dev/null)
if echo "$STATUS" | grep -q '"enabled"'; then
  ENABLED=$(echo "$STATUS" | grep -oP '"enabled":\s*\w+' | awk -F: '{print $2}' | tr -d ' ,')
  ok "API отвечает: lockdown enabled=${ENABLED}"
else
  bad "API не отвечает на /lockdown/status — сервис haproxy-node лежит?"
fi

# 8. сервис haproxy-node
if systemctl is-active --quiet haproxy-node; then
  ok "systemd haproxy-node: active"
else
  bad "systemd haproxy-node: НЕ active"
fi

if systemctl is-active --quiet haproxy; then
  ok "systemd haproxy: active"
else
  bad "systemd haproxy: НЕ active"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo -e "${G}✅ Всё в порядке. Если клиент не коннектится — его IP не в whitelist.${NC}"
  echo "   Проверь свой IP:  sudo bash check-my-ip.sh \$(curl -s ifconfig.me)"
else
  echo -e "${R}❌ Найдено $FAIL проблем — см. отметки ✗ выше.${NC}"
fi
