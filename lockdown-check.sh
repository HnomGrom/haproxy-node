#!/usr/bin/env bash
# Проверка: реально ли работает lockdown-whitelist на VLESS-портах.
#
# Ищет типичные дыры:
#   • match-set правило стоит ПОСЛЕ общего ACCEPT → whitelist обходится
#   • ipset пустой / не того типа
#   • IPv6 не защищён (атака идёт через v6)
#   • UDP-атака проходит мимо TCP-правила
#   • NAT/PREROUTING редиректит до INPUT
#   • Пакеты идут на API/SSH порты, а не на VLESS
#   • ESTABLISHED соединения бесконечно живут через conntrack
#   • Канал насыщен upstream'ом — iptables-фильтр бессилен
#
# Usage:  sudo bash lockdown-check.sh
#         sudo bash lockdown-check.sh > /tmp/lockdown-check.log

set +e

# ───── Colors ─────
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
else
  R=''; G=''; Y=''; B=''; NC=''
fi

hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
sub()  { echo -e "${G}--- $* ---${NC}"; }
ok()   { echo -e "${G}✓ $*${NC}"; }
warn() { echo -e "${Y}⚠ $*${NC}"; }
crit() { echo -e "${R}🔴 $*${NC}"; }

[ "$EUID" -eq 0 ] || { crit "Запусти как root: sudo bash $0"; exit 1; }

# ───── Параметры (подхватываем из .env если есть) ─────
ENV_FILE="/opt/haproxy-node/.env"
if [ -f "${ENV_FILE}" ]; then
  PORT_MIN=$(awk -F= '/^FRONTEND_PORT_MIN=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
  PORT_MAX=$(awk -F= '/^FRONTEND_PORT_MAX=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
  API_PORT=$(awk -F= '/^PORT=/ {gsub(/"/,""); print $2}' "${ENV_FILE}")
fi
PORT_MIN="${PORT_MIN:-10000}"
PORT_MAX="${PORT_MAX:-65000}"
API_PORT="${API_PORT:-3000}"
SET="vless_lockdown"

echo -e "${B}╔════════════════════════════════════════════════╗${NC}"
echo -e "${B}║      LOCKDOWN HEALTH CHECK                     ║${NC}"
echo -e "${B}║      $(date '+%Y-%m-%d %H:%M:%S')                       ║${NC}"
echo -e "${B}╚════════════════════════════════════════════════╝${NC}"
echo "   Ports:    ${PORT_MIN}:${PORT_MAX} (VLESS), :${API_PORT} (API), :22 (SSH)"
echo "   Ipset:    ${SET}"

# Счётчик критических проблем
CRIT=0
inc_crit() { CRIT=$((CRIT+1)); }

# ═══════════════════════════════════════════════════════════
# 1. IPSET: существует, правильный тип, не пустой
# ═══════════════════════════════════════════════════════════
hdr "1. IPSET ${SET}"

if ! command -v ipset >/dev/null; then
  crit "ipset не установлен"; inc_crit
else
  IPSET_INFO=$(ipset list -t "${SET}" 2>/dev/null)
  if [ -z "${IPSET_INFO}" ]; then
    crit "set '${SET}' НЕ СУЩЕСТВУЕТ — lockdown физически невозможен"
    inc_crit
  else
    TYPE=$(echo "${IPSET_INFO}" | awk -F': ' '/^Type/ {print $2; exit}')
    SIZE=$(echo "${IPSET_INFO}" | awk -F': ' '/Number of entries/ {print $2; exit}')

    if [ "${TYPE}" = "hash:net" ]; then
      ok  "тип: hash:net"
    else
      crit "тип: '${TYPE}' (должен быть hash:net) — CIDR-записи не добавятся"
      inc_crit
    fi

    if [ "${SIZE:-0}" -gt 0 ]; then
      ok  "записей: ${SIZE}"
    else
      crit "записей: 0 — при активном lockdown ВСЕ клиенты дропаются"
      inc_crit
    fi

    echo "   первые 5 записей:"
    ipset list "${SET}" 2>/dev/null | awk '/^[0-9]+\./ {print "     "$0; if (++c>=5) exit}'
  fi
fi

# ═══════════════════════════════════════════════════════════
# 2. IPTABLES: match-set правило в INPUT
# ═══════════════════════════════════════════════════════════
hdr "2. IPTABLES match-set правило"

MATCH_RULE=$(iptables -L INPUT -n -v -x --line-numbers 2>/dev/null | grep "match-set ${SET}")
if [ -z "${MATCH_RULE}" ]; then
  crit "match-set ${SET} правило НЕ АКТИВНО — lockdown выключен"
  inc_crit
else
  ok "match-set правило активно:"
  echo "${MATCH_RULE}" | sed 's/^/   /'
  MATCH_LINE=$(echo "${MATCH_RULE}" | awk '{print $1}')
fi

# ═══════════════════════════════════════════════════════════
# 3. ПОРЯДОК ПРАВИЛ: нет ли ACCEPT для VLESS-портов ПЕРЕД match-set?
# ═══════════════════════════════════════════════════════════
hdr "3. ПОРЯДОК ПРАВИЛ — не обходится ли lockdown?"

BYPASS_RULES=$(iptables -L INPUT -n -v -x --line-numbers 2>/dev/null \
  | awk -v pmin="${PORT_MIN}" -v pmax="${PORT_MAX}" -v set="${SET}" '
    /match-set/ && index($0, set) { found=1 }
    !found && /ACCEPT/ && /tcp/ && ( $0 ~ "dpts:"pmin":"pmax || $0 ~ "dpt:"pmin":"pmax ) { print }
  ')

if [ -n "${BYPASS_RULES}" ]; then
  crit "Есть ACCEPT для ${PORT_MIN}:${PORT_MAX} ВЫШЕ match-set — ВЕСЬ whitelist обходится:"
  echo "${BYPASS_RULES}" | sed 's/^/   /'
  inc_crit
else
  ok "нет ACCEPT-правил перед match-set на VLESS-диапазоне"
fi

# Проверка ESTABLISHED — отдельный слой
EST_RULE=$(iptables -L INPUT -n -v -x --line-numbers 2>/dev/null | grep -E "conntrack.*ESTABLISHED|state ESTABLISHED")
if [ -n "${EST_RULE}" ]; then
  warn "ESTABLISHED-ACCEPT правило есть (это норма):"
  echo "${EST_RULE}" | sed 's/^/   /'
  echo "   но! это значит уже-установленные соединения ПРОХОДЯТ — новые всё равно фильтруются"
fi

# ═══════════════════════════════════════════════════════════
# 4. ПОЛИТИКА INPUT
# ═══════════════════════════════════════════════════════════
hdr "4. INPUT policy"
POLICY=$(iptables -L INPUT -n 2>/dev/null | awk '/^Chain INPUT/ {gsub(/[)(]/,""); print $4}')
if [ "${POLICY}" = "DROP" ]; then
  ok "policy: DROP (правильно — всё что не разрешено явно, дропается)"
else
  crit "policy: ${POLICY} — НЕ DROP, фильтрация бесполезна если нет явных DROP-правил"
  inc_crit
fi

# ═══════════════════════════════════════════════════════════
# 5. СЧЁТЧИКИ ПАКЕТОВ — пакеты реально бьются о lockdown?
# ═══════════════════════════════════════════════════════════
hdr "5. СЧЁТЧИКИ match-set правила"

if [ -n "${MATCH_RULE}" ]; then
  BEFORE_PKTS=$(echo "${MATCH_RULE}" | awk '{print $2}')
  echo "   текущие счётчики: match-set pkts=${BEFORE_PKTS}"
  echo "   ждём 5 сек для дельты..."
  sleep 5
  AFTER_RULE=$(iptables -L INPUT -n -v -x --line-numbers 2>/dev/null | grep "match-set ${SET}")
  AFTER_PKTS=$(echo "${AFTER_RULE}" | awk '{print $2}')
  DELTA=$(( AFTER_PKTS - BEFORE_PKTS ))
  DELTA_PPS=$(( DELTA / 5 ))

  # Сумма счётчиков ACCEPT-правил
  TOTAL_ACCEPT_PKTS=$(iptables -L INPUT -n -v -x 2>/dev/null | awk '/ACCEPT/ {sum += $1} END {print sum+0}')

  printf "   match-set ACCEPT: +%d пакетов / 5s = %d pps\n" "${DELTA}" "${DELTA_PPS}"

  if [ "${DELTA}" -eq 0 ] && [ -n "${BYPASS_RULES}" ]; then
    crit "match-set правило не ловит ни одного пакета, но есть bypass-правила → весь трафик идёт мимо"
  elif [ "${DELTA_PPS}" -gt 0 ]; then
    ok "match-set правило активно обрабатывает пакеты"
  fi
fi

# Сравнить dropped пакеты против общего RX
sub "nf drops (ядерная статистика)"
if [ -f /proc/net/netfilter/nf_conntrack ]; then
  CONNTRACK_COUNT=$(wc -l < /proc/net/netfilter/nf_conntrack 2>/dev/null)
  CONNTRACK_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
  echo "   conntrack: ${CONNTRACK_COUNT} / ${CONNTRACK_MAX}"
  if [ -n "${CONNTRACK_MAX}" ] && [ "${CONNTRACK_COUNT}" -gt 0 ]; then
    PCT=$(( CONNTRACK_COUNT * 100 / CONNTRACK_MAX ))
    if [ "${PCT}" -gt 80 ]; then
      crit "conntrack занят на ${PCT}% — при 100% все новые коннекты дропнутся системно"
      inc_crit
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════
# 6. IPv6 — отдельная цепочка
# ═══════════════════════════════════════════════════════════
hdr "6. IPv6 lockdown"

if command -v ip6tables >/dev/null && ip6tables -S INPUT &>/dev/null; then
  V6_MATCH=$(ip6tables -L INPUT -n -v 2>/dev/null | grep -E "match-set (vless_lockdown|${SET})")
  V6_BYPASS=$(ip6tables -L INPUT -n -v 2>/dev/null | grep -E "ACCEPT.*tcp.*(dpts|dpt):${PORT_MIN}:${PORT_MAX}")

  if [ -z "${V6_MATCH}" ] && [ -n "${V6_BYPASS}" ]; then
    crit "IPv6 — нет match-set правила, но есть общий ACCEPT для ${PORT_MIN}:${PORT_MAX}"
    crit "  → атака через IPv6 полностью обходит защиту"
    inc_crit
  elif [ -z "${V6_MATCH}" ]; then
    warn "IPv6 — match-set правила нет (возможно lockdown только для IPv4)"
  else
    ok "IPv6 match-set активен"
  fi

  V6_POLICY=$(ip6tables -L INPUT -n 2>/dev/null | awk '/^Chain INPUT/ {gsub(/[)(]/,""); print $4}')
  if [ "${V6_POLICY}" != "DROP" ]; then
    warn "IPv6 INPUT policy: ${V6_POLICY} (не DROP)"
  fi
else
  ok "IPv6 не активен на хосте — пропускаем"
fi

# ═══════════════════════════════════════════════════════════
# 7. UDP — атака может идти мимо TCP-правил
# ═══════════════════════════════════════════════════════════
hdr "7. UDP защита"

UDP_DROP=$(iptables -L INPUT -n -v 2>/dev/null | grep -E "DROP.*udp.*(dpts|dpt):${PORT_MIN}:${PORT_MAX}")
UDP_ACCEPT=$(iptables -L INPUT -n -v 2>/dev/null | grep -E "ACCEPT.*udp.*(dpts|dpt):${PORT_MIN}:${PORT_MAX}")

if [ -n "${UDP_ACCEPT}" ]; then
  crit "Есть ACCEPT для UDP на VLESS-диапазоне — UDP-флуд проходит:"
  echo "${UDP_ACCEPT}" | sed 's/^/   /'
  inc_crit
elif [ "${POLICY}" = "DROP" ]; then
  ok "UDP на ${PORT_MIN}:${PORT_MAX} дропается policy (VLESS только TCP)"
else
  warn "нет явного DROP для UDP и INPUT policy = ${POLICY}"
fi

# UDP-нагрузка из tcpdump (5 сек)
sub "текущий UDP-трафик (5 сек сэмпл)"
IF=$(ip route | awk '/default/ {print $5; exit}')
if command -v tcpdump >/dev/null && [ -n "${IF}" ]; then
  UDP_PKTS=$(timeout 5 tcpdump -i "${IF}" -nn -c 1000 'udp and not port 53' 2>/dev/null | wc -l)
  echo "   UDP-пакетов за 5 сек: ${UDP_PKTS}"
  if [ "${UDP_PKTS}" -gt 100 ]; then
    warn "заметный UDP-трафик (${UDP_PKTS} за 5 сек) — возможно UDP-флуд"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 8. NAT / PREROUTING — нет ли редиректа мимо INPUT?
# ═══════════════════════════════════════════════════════════
hdr "8. NAT PREROUTING"

NAT_RULES=$(iptables -t nat -L PREROUTING -n -v 2>/dev/null | awk 'NR>2 && NF > 0 && !/^Chain/')
if [ -n "${NAT_RULES}" ]; then
  echo "${NAT_RULES}" | sed 's/^/   /'
  if echo "${NAT_RULES}" | grep -qE "DNAT|REDIRECT"; then
    warn "Есть DNAT/REDIRECT в PREROUTING — пакеты могут уходить мимо INPUT-фильтров"
    warn "  (HAProxy-node проверялось без NAT; если вручную добавили — проверь)"
  fi
else
  ok "PREROUTING пуст (правильно для HAProxy-node)"
fi

# ═══════════════════════════════════════════════════════════
# 9. АКТИВНЫЕ СОЕДИНЕНИЯ — реально кто-то сейчас подключён?
# ═══════════════════════════════════════════════════════════
hdr "9. АКТИВНЫЕ СОЕДИНЕНИЯ на VLESS-портах"

if command -v ss >/dev/null; then
  VLESS_CONNS=$(ss -Hntn "( sport >= :${PORT_MIN} and sport <= :${PORT_MAX} )" 2>/dev/null | wc -l)
  echo "   TCP коннектов на ${PORT_MIN}:${PORT_MAX}: ${VLESS_CONNS}"

  # Топ-10 клиентских IP
  sub "топ-10 удалённых IP по числу соединений"
  ss -Hntn "( sport >= :${PORT_MIN} and sport <= :${PORT_MAX} )" 2>/dev/null \
    | awk '{print $5}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn | head -10 \
    | sed 's/^/   /'

  # Сколько из них — в whitelist?
  sub "сверка с whitelist"
  WL_FILE=$(mktemp)
  ipset list "${SET}" 2>/dev/null | awk '/^[0-9]+\./' > "${WL_FILE}"
  MATCHED=0
  UNMATCHED=0
  TOP_IPS=$(ss -Hntn "( sport >= :${PORT_MIN} and sport <= :${PORT_MAX} )" 2>/dev/null \
    | awk '{print $5}' | sed 's/:[0-9]*$//' | sort -u)
  for ip in ${TOP_IPS}; do
    [ -z "$ip" ] && continue
    # точное совпадение
    if grep -qxF "${ip}" "${WL_FILE}"; then
      MATCHED=$((MATCHED+1))
    else
      UNMATCHED=$((UNMATCHED+1))
    fi
  done
  rm -f "${WL_FILE}"
  echo "   IP точно в whitelist (точные /32): ${MATCHED}"
  echo "   IP не в /32 whitelist (могут быть в CIDR — или прошли мимо): ${UNMATCHED}"

  if [ "${UNMATCHED}" -gt "${MATCHED}" ] && [ -n "${MATCH_RULE}" ]; then
    warn "много IP вне точных записей — это нормально если у тебя CIDR-диапазоны"
    warn "но если в whitelist только /32 — это сигнал что пакеты обходят правило"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 10. СЕТЕВАЯ НАГРУЗКА
# ═══════════════════════════════════════════════════════════
hdr "10. СЕТЕВАЯ НАГРУЗКА (5 сек сэмпл)"

if [ -n "${IF}" ]; then
  R1=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
  B1=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
  T1=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
  D1=$(cat /sys/class/net/$IF/statistics/rx_dropped 2>/dev/null)
  sleep 5
  R2=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
  B2=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
  T2=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
  D2=$(cat /sys/class/net/$IF/statistics/rx_dropped 2>/dev/null)

  RX_PPS=$(( (R2-R1)/5 ))
  RX_MBPS=$(( (B2-B1)*8/5/1024/1024 ))
  TX_PPS=$(( (T2-T1)/5 ))
  NIC_DROP=$(( D2-D1 ))

  echo "   RX: ${RX_PPS} pps / ${RX_MBPS} Mbps"
  echo "   TX: ${TX_PPS} pps"
  echo "   NIC dropped: ${NIC_DROP} (за 5 сек)"

  if [ "${RX_PPS}" -gt 50000 ] && [ "${TX_PPS}" -lt 500 ]; then
    ok "RX >> TX — server глушит трафик (lockdown РАБОТАЕТ, канал насыщается)"
  elif [ "${RX_PPS}" -gt 50000 ] && [ "${TX_PPS}" -gt 10000 ]; then
    crit "RX высокий + TX тоже высокий → сервер ОТВЕЧАЕТ на атаку (lockdown НЕ работает на этом трафике)"
    inc_crit
  fi

  if [ "${NIC_DROP}" -gt 0 ]; then
    warn "NIC дропает ${NIC_DROP} пакетов/5с — канал/hardware насыщен (это upstream-проблема, iptables не поможет)"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 11. ТИП АТАКИ — куда идут пакеты?
# ═══════════════════════════════════════════════════════════
hdr "11. ТИП АТАКИ (tcpdump 5 сек)"

if command -v tcpdump >/dev/null && [ -n "${IF}" ]; then
  TCP_DUMP=$(mktemp)
  timeout 5 tcpdump -i "${IF}" -nn -c 3000 'tcp' 2>/dev/null > "${TCP_DUMP}"

  sub "топ dst-портов"
  awk '/IP / {
    split($5, a, ".");
    port = a[5]; sub(":", "", port);
    if (port ~ /^[0-9]+$/) cnt[port]++
  } END {
    for (p in cnt) printf "%8d  :%s\n", cnt[p], p
  }' "${TCP_DUMP}" | sort -rn | head -10 | sed 's/^/   /'

  sub "топ src-IP (атакующие)"
  awk '/IP / {
    split($3, a, ".");
    ip = a[1]"."a[2]"."a[3]"."a[4]
    cnt[ip]++
  } END {
    for (i in cnt) printf "%8d  %s\n", cnt[i], i
  }' "${TCP_DUMP}" | sort -rn | head -10 | sed 's/^/   /'

  sub "SYN vs прочие (признак SYN-флуда)"
  SYN_CNT=$(grep -c 'Flags \[S\]' "${TCP_DUMP}")
  TOTAL_CNT=$(wc -l < "${TCP_DUMP}")
  echo "   SYN: ${SYN_CNT} / всего: ${TOTAL_CNT}"
  if [ "${TOTAL_CNT}" -gt 0 ]; then
    PCT=$(( SYN_CNT * 100 / TOTAL_CNT ))
    if [ "${PCT}" -gt 70 ]; then
      warn "${PCT}% SYN — это SYN-флуд (ожидаемо дропается lockdown'ом)"
    fi
  fi

  rm -f "${TCP_DUMP}"
fi

# ═══════════════════════════════════════════════════════════
# 12. ФИНАЛЬНЫЙ ВЕРДИКТ
# ═══════════════════════════════════════════════════════════
hdr "ВЕРДИКТ"

if [ "${CRIT}" -eq 0 ]; then
  ok "Все критические проверки пройдены — lockdown настроен корректно"
  echo
  echo "   Если атака продолжает достигать сервера:"
  echo "   • Скорее всего это volumetric-атака (канал насыщен upstream'ом)."
  echo "   • iptables дропает пакеты, но они уже заняли полосу до сервера."
  echo "   • Решение — upstream-защита: Selectel Anti-DDoS, DDoS-Guard, Cloudflare Spectrum."
  echo "   • Проверь RX Mbps — если близко к полосе (например 1 Gbps) — это канал."
else
  crit "Найдено ${CRIT} критических проблем — см. пометки 🔴 выше"
  echo
  echo "   Типичные быстрые фиксы:"
  echo "   • \"есть ACCEPT перед match-set\"  → iptables -D INPUT <номер>"
  echo "   • \"тип не hash:net\"              → bash install.sh (пересоздаст)"
  echo "   • \"записей 0\"                    → POST /lockdown/on {ips:[...]} с реальными IP"
  echo "   • \"IPv6 не защищён\"              → атака идёт через v6, добавь ip6tables правила"
fi

echo
echo -e "${B}═══════════════════════════════════════════════${NC}"
