  #!/usr/bin/env bash
  # Полный отчёт по атаке на сервер.
  # Определяет: идёт ли атака / какой тип / откуда / насколько серьёзная.
  #
  # Usage:  sudo bash attack-check.sh
  #         sudo bash attack-check.sh > /tmp/attack.log 2>&1

  set +e

  # ───── Colors ─────
  if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
  else
    R=''; G=''; Y=''; B=''; NC=''
  fi

  hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
  sub()  { echo -e "${G}--- $* ---${NC}"; }
  warn() { echo -e "${Y}⚠ $*${NC}"; }
  crit() { echo -e "${R}🔴 $*${NC}"; }
  ok()   { echo -e "${G}✓ $*${NC}"; }

  # Пороги для вердикта
  PPS_LOW=20000       # >20k pps = подозрительно
  PPS_HIGH=100000     # >100k pps = явная атака
  CONN_LOW=200        # >200 TCP коннектов = подозрительно
  CONN_HIGH=1000      # >1000 TCP = явная атака
  CONNTRACK_HIGH=80   # >80% = проблема

  # Установить зависимости тихо
  command -v tcpdump >/dev/null || apt-get install -y -qq tcpdump >/dev/null 2>&1
  command -v jq      >/dev/null || apt-get install -y -qq jq >/dev/null 2>&1
  command -v socat   >/dev/null || apt-get install -y -qq socat >/dev/null 2>&1

  echo -e "${B}╔════════════════════════════════════════════════╗${NC}"
  echo -e "${B}║          ATTACK DETECTION REPORT               ║${NC}"
  echo -e "${B}║   $(date '+%Y-%m-%d %H:%M:%S')                       ║${NC}"
  echo -e "${B}╚════════════════════════════════════════════════╝${NC}"

  # ═════════════════════════ 1. БАЗА ═════════════════════════
  hdr "1. СИСТЕМА"
  echo "hostname:  $(hostname)"
  echo "uptime:    $(uptime -p 2>/dev/null)"
  echo "load:      $(awk '{print $1, $2, $3}' /proc/loadavg)  ($(nproc) ядер)"
  echo "ram:       $(free -h | awk '/^Mem:/ {print $3" / "$2}')"

  # ═════════════════════════ 2. СЕТЬ — ПОТОК ═════════════════════════
  hdr "2. СЕТЕВАЯ НАГРУЗКА (5 сек сэмпл)"
  IF=$(ip route | awk '/default/ {print $5; exit}')
  R1=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
  B1=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
  T1=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
  TB1=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null)
  D1=$(cat /sys/class/net/$IF/statistics/rx_dropped 2>/dev/null)
  E1=$(cat /sys/class/net/$IF/statistics/rx_errors 2>/dev/null)
  sleep 5
  R2=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
  B2=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
  T2=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
  TB2=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null)
  D2=$(cat /sys/class/net/$IF/statistics/rx_dropped 2>/dev/null)
  E2=$(cat /sys/class/net/$IF/statistics/rx_errors 2>/dev/null)

  RX_PPS=$(( (R2-R1)/5 ))
  RX_MBPS=$(( (B2-B1)*8/5/1024/1024 ))
  TX_PPS=$(( (T2-T1)/5 ))
  TX_MBPS=$(( (TB2-TB1)*8/5/1024/1024 ))
  NIC_DROP=$(( D2-D1 ))
  NIC_ERR=$(( E2-E1 ))

  printf "   %-12s %-12s %-12s %-12s %-10s\n" "RX pps" "RX Mbps" "TX pps" "TX Mbps" "dropped"
  printf "   %-12s %-12s %-12s %-12s %-10s\n" "${RX_PPS}" "${RX_MBPS}" "${TX_PPS}" "${TX_MBPS}" "${NIC_DROP}"
  echo

  # Интерпретация
  if   [ "${RX_PPS}" -gt "${PPS_HIGH}" ] 2>/dev/null; then
    crit "RX pps ${RX_PPS} — сильная атака"
  elif [ "${RX_PPS}" -gt "${PPS_LOW}" ] 2>/dev/null; then
    warn "RX pps ${RX_PPS} — подозрительная активность"
  else
    ok "RX pps ${RX_PPS} — норма"
  fi

  if [ "${TX_PPS}" -lt $((RX_PPS/10)) ] 2>/dev/null && [ "${RX_PPS}" -gt 1000 ]; then
    ok "TX << RX (${TX_PPS} vs ${RX_PPS}) — защита дропает, сервер НЕ отвечает атаке"
  elif [ "${TX_PPS}" -gt $((RX_PPS*3/4)) ] 2>/dev/null && [ "${RX_PPS}" -gt 1000 ]; then
    crit "TX ≈ RX (${TX_PPS} vs ${RX_PPS}) — сервер отвечает на атаку (defence не работает?)"
  fi

  [ "${NIC_DROP}" -gt 100 ] 2>/dev/null && crit "NIC dropped ${NIC_DROP}/5s — сетевая карта переполнена"
  [ "${NIC_ERR}" -gt 10 ] 2>/dev/null && crit "NIC errors ${NIC_ERR}/5s — физическая проблема"

  # ═════════════════════════ 3. TCP СОСТОЯНИЯ ═════════════════════════
  hdr "3. TCP СОСТОЯНИЯ"
  ss -s | head -3

  echo
  sub "разбивка по состояниям"
  SS_OUT=$(ss -Hnt 2>/dev/null)
  echo "$SS_OUT" | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

  # Детект slow-attack
  FW1=$(echo "$SS_OUT" | awk '$1=="FIN-WAIT-1"' | wc -l)
  FW2=$(echo "$SS_OUT" | awk '$1=="FIN-WAIT-2"' | wc -l)
  ESTAB=$(echo "$SS_OUT" | awk '$1=="ESTAB"' | wc -l)
  SYNRECV=$(echo "$SS_OUT" | awk '$1=="SYN-RECV"' | wc -l)

  echo
  if [ "${SYNRECV}" -gt 100 ] 2>/dev/null; then
    crit "SYN-RECV ${SYNRECV} — классический SYN-flood"
  fi
  if [ $((FW1+FW2)) -gt "${ESTAB}" ] 2>/dev/null && [ "${ESTAB}" -gt 50 ]; then
    warn "FIN-WAIT ($((FW1+FW2))) > ESTAB (${ESTAB}) — slow-attack / много зависших"
  fi

  # ═════════════════════════ 4. CONNTRACK ═════════════════════════
  hdr "4. CONNTRACK"
  if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
    CNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    PCT=$((CNT*100/MAX))
    echo "count: ${CNT} / max: ${MAX} (${PCT}%)"
    if [ "${PCT}" -gt "${CONNTRACK_HIGH}" ] 2>/dev/null; then
      crit "conntrack ${PCT}% — близко к переполнению, пакеты дропаются ядром"
    else
      ok "conntrack ${PCT}% — норма"
    fi
  else
    echo "conntrack не загружен"
  fi

  # ═════════════════════════ 5. КОННЕКТЫ ═════════════════════════
  hdr "5. КОННЕКТЫ — ВХОДЯЩИЕ vs ИСХОДЯЩИЕ"

  # Получить listening ports чтобы определить что входящее
  LOCAL_PORTS=$(ss -Hnltp 2>/dev/null | awk '{print $4}' | grep -oE ':[0-9]+$' | tr -d ':' | sort -un)

  # Коннект считается входящим если LOCAL port — это один из LISTENING портов
  IN_COUNT=0
  OUT_COUNT=0
  declare -A IN_IPS OUT_DSTS

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    STATE=$(echo "$line" | awk '{print $1}')
    LOCAL=$(echo "$line" | awk '{print $4}')
    PEER=$(echo "$line" | awk '{print $5}')
    LPORT=$(echo "$LOCAL" | grep -oE ':[0-9]+$' | tr -d ':')

    if echo "$LOCAL_PORTS" | grep -qw "$LPORT"; then
      IN_COUNT=$((IN_COUNT+1))
      PIP=$(echo "$PEER" | sed 's/\[.*\]/IPv6/' | cut -d: -f1)
      [ -n "$PIP" ] && IN_IPS[$PIP]=$((${IN_IPS[$PIP]:-0}+1))
    else
      OUT_COUNT=$((OUT_COUNT+1))
      PIP=$(echo "$PEER" | sed 's/\[.*\]/IPv6/' | cut -d: -f1)
      [ -n "$PIP" ] && OUT_DSTS[$PIP]=$((${OUT_DSTS[$PIP]:-0}+1))
    fi
  done < <(ss -Hnt state established 2>/dev/null)

  echo "Входящих (к нашим LISTEN-портам):      ${IN_COUNT}"
  echo "Исходящих (наш Xray ходит наружу):      ${OUT_COUNT}"
  echo

  sub "ТОП-15 ВХОДЯЩИХ — это клиенты (должны быть ожидаемые: фронт, панель)"
  for ip in "${!IN_IPS[@]}"; do
    echo "${IN_IPS[$ip]} $ip"
  done | sort -rn | head -15

  echo
  sub "ТОП-15 ИСХОДЯЩИХ — это куда Xray проксирует (Google, Meta, Telegram и т.д.)"
  for ip in "${!OUT_DSTS[@]}"; do
    echo "${OUT_DSTS[$ip]} $ip"
  done | sort -rn | head -15

  echo
  sub "ТОП-10 /24 подсетей всех коннектов"
  ss -Hnt 2>/dev/null | awk '{print $5}' | grep -vE '^\[|^$' | cut -d: -f1 | \
    awk -F. 'NF==4 {print $1"."$2"."$3".0/24"}' | sort | uniq -c | sort -rn | head -10

  # ═════════════════════════ 6. ТИПЫ ПАКЕТОВ (tcpdump) ═════════════════════════
  hdr "6. ТИПЫ ВХОДЯЩИХ ПАКЕТОВ (10 сек сэмпл)"
  DUMP=/tmp/attack-check-dump.$$
  timeout 10 tcpdump -nn -i ${IF} -c 30000 2>/dev/null > "${DUMP}"

  PKT_TOTAL=$(wc -l < "${DUMP}")
  echo "собрано пакетов: ${PKT_TOTAL}"

  if [ "${PKT_TOTAL}" -gt 0 ]; then
    awk '/Flags/ {
      if ($0 ~ /\[S\]/) print "SYN"
      else if ($0 ~ /\[S\./) print "SYNACK"
      else if ($0 ~ /\[R\./) print "RST-ACK"
      else if ($0 ~ /\[R\]/) print "RST"
      else if ($0 ~ /\[P\./) print "PSH-ACK (данные)"
      else if ($0 ~ /\[F/) print "FIN"
      else if ($0 ~ /\[\.\]/) print "ACK"
    }
    /ICMP/     {print "ICMP"}
    /\bUDP/    {print "UDP"}
    ' "${DUMP}" | sort | uniq -c | sort -rn
  fi

  # Детектим SYN-flood
  SYN_COUNT=$(grep -c '\[S\]' "${DUMP}" 2>/dev/null)
  SYNACK_COUNT=$(grep -c '\[S\.\]' "${DUMP}" 2>/dev/null)
  ACK_COUNT=$(grep -c '\[\.\]' "${DUMP}" 2>/dev/null)

  echo
  if [ "${SYN_COUNT}" -gt $((PKT_TOTAL/2)) ] 2>/dev/null; then
    crit "SYN-flood: ${SYN_COUNT} SYN из ${PKT_TOTAL} пакетов (${#SYN_COUNT}%)"
  fi
  if [ "${SYNACK_COUNT}" -lt 50 ] 2>/dev/null && [ "${SYN_COUNT}" -gt 1000 ]; then
    ok "сервер почти не отвечает на SYN (${SYNACK_COUNT} SYNACK на ${SYN_COUNT} SYN) — защита работает"
  fi

  # ═════════════════════════ 7. ТОП DST ПОРТОВ (куда бьют) ═════════════════════════
  hdr "7. ТОП DST ПОРТОВ (куда целится атака)"
  if [ "${PKT_TOTAL}" -gt 0 ]; then
    grep "IP" "${DUMP}" | awk '{print $5}' | awk -F. '{print $NF}' | tr -d ':' | \
      grep -E '^[0-9]+$' | sort | uniq -c | sort -rn | head -15
  fi

  # ═════════════════════════ 8. ТОП АТАКУЮЩИХ IP (tcpdump) ═════════════════════════
  hdr "8. ТОП-20 ИСТОЧНИКОВ ПАКЕТОВ (tcpdump)"
  if [ "${PKT_TOTAL}" -gt 0 ]; then
    grep "IP" "${DUMP}" | awk '{print $3}' | \
      awk -F. 'NF>=4 {print $1"."$2"."$3"."$4}' | \
      sort | uniq -c | sort -rn | head -20
  fi

  # ═════════════════════════ 9. ГЕОГРАФИЯ ═════════════════════════
  hdr "9. ГЕОГРАФИЯ (ip-api.com)"
  TOP_IPS=$(grep "IP" "${DUMP}" 2>/dev/null | awk '{print $3}' | \
    awk -F. 'NF>=4 {print $1"."$2"."$3"."$4}' | \
    grep -vE '^(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[0-1]))\.' | \
    sort | uniq -c | sort -rn | head -15 | awk '{print $2}')

  if [ -n "${TOP_IPS}" ] && command -v jq >/dev/null; then
    jq -Rn '[inputs|select(length>0)]' <<< "${TOP_IPS}" | \
      curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
      --data-binary @- http://ip-api.com/batch?fields=query,countryCode,as,asname,mobile,hosting 2>/dev/null | \
      jq -r '.[] | "\(.query)\t\(.countryCode // "??")\t\(.as // "")\t\(.asname // "")\(if .mobile then " MOBILE" else "" end)\(if .hosting then " HOSTING" else "" end)"' | \
      column -t -s $'\t' | head -15
  else
    echo "пропускаю (нет публичных IP или jq)"
  fi

  # ═════════════════════════ 10. IPTABLES ДРОПЫ ═════════════════════════
  hdr "10. IPTABLES — ЧТО ДРОПАЕТСЯ"
  echo "policy INPUT:  $(iptables -S INPUT 2>/dev/null | head -1)"
  echo

  sub "топ-5 правил по числу пакетов"
  iptables -L INPUT -nv --line-numbers 2>/dev/null | awk 'NR>2 && $2+0 > 1000' | \
    sort -k2 -rn | head -5

  echo
  sub "ipset banlists (если есть)"
  for set in attackers attackers_net api_whitelist ssh_whitelist; do
    if ipset list -n 2>/dev/null | grep -qx "${set}"; then
      N=$(ipset list "${set}" 2>/dev/null | grep 'Number of entries' | awk '{print $NF}')
      printf "  %-20s %s записей\n" "${set}" "${N}"
    fi
  done

  # ═════════════════════════ 11. BACKEND (чтоб не перепутать) ═════════════════════════
  hdr "11. НАШИ BACKEND СЕРВЕРЫ (не считать атакой!)"
  if [ -f /opt/haproxy-node/.env ]; then
    API_KEY=$(grep "^API_KEY=" /opt/haproxy-node/.env | cut -d'"' -f2)
    API_PORT=$(grep "^PORT=" /opt/haproxy-node/.env | cut -d= -f2)
    if [ -n "${API_KEY}" ] && [ -n "${API_PORT}" ]; then
      curl -s --max-time 3 -H "x-api-key: ${API_KEY}" \
        "http://127.0.0.1:${API_PORT}/servers" 2>/dev/null | \
        grep -oE '"ip":"[0-9.]+"' | cut -d'"' -f4 || echo "API недоступен"
    fi
  fi

  # ═════════════════════════ 12. ВЕРДИКТ ═════════════════════════
  hdr "12. ВЕРДИКТ"

  SCORE=0
  REASONS=""

  [ "${RX_PPS}" -gt "${PPS_HIGH}" ] 2>/dev/null && { SCORE=$((SCORE+3)); REASONS="${REASONS}\n  • RX pps ${RX_PPS} (>${PPS_HIGH})"; }
  [ "${RX_PPS}" -gt "${PPS_LOW}" ] 2>/dev/null && [ "${RX_PPS}" -le "${PPS_HIGH}" ] 2>/dev/null && { SCORE=$((SCORE+1)); REASONS="${REASONS}\n  • RX pps ${RX_PPS} (подозрительно)"; }
  [ "${SYNRECV}" -gt 100 ] 2>/dev/null && { SCORE=$((SCORE+2)); REASONS="${REASONS}\n  • SYN-RECV ${SYNRECV} (SYN-flood)"; }
  [ "${NIC_DROP}" -gt 100 ] 2>/dev/null && { SCORE=$((SCORE+2)); REASONS="${REASONS}\n  • NIC dropped ${NIC_DROP}"; }
  [ "${PCT:-0}" -gt 80 ] 2>/dev/null && { SCORE=$((SCORE+2)); REASONS="${REASONS}\n  • conntrack переполнен"; }
  [ "${TX_PPS}" -gt $((RX_PPS*3/4)) ] 2>/dev/null && [ "${RX_PPS}" -gt 1000 ] && { SCORE=$((SCORE+3)); REASONS="${REASONS}\n  • TX≈RX: сервер отвечает на атаку"; }

  echo
  if [ "${SCORE}" -eq 0 ]; then
    ok "ATTACK LEVEL: NONE ─── атаки нет, сервер работает спокойно"
  elif [ "${SCORE}" -le 2 ]; then
    warn "ATTACK LEVEL: LOW ─── подозрительная активность"
    echo -e "Признаки:${REASONS}"
  elif [ "${SCORE}" -le 5 ]; then
    crit "ATTACK LEVEL: MEDIUM ─── идёт атака, но защита держит"
    echo -e "Признаки:${REASONS}"
  else
    crit "ATTACK LEVEL: HIGH ─── сильная атака, требуется реакция!"
    echo -e "Признаки:${REASONS}"
    echo
    echo -e "${R}РЕКОМЕНДАЦИИ:${NC}"
    printf '%s\n' \
      "  1. Увеличить conntrack (если переполнен):" \
      "     sysctl -w net.netfilter.nf_conntrack_max=4194304" \
      "     conntrack -F" \
      "  2. Забанить топ-IP (в другом окне):" \
      "     iptables -I INPUT 1 -s IP_HERE -j DROP" \
      "  3. Временно закрыть VLESS-диапазон если не справляется:" \
      "     iptables -D INPUT -p tcp -m multiport --dports 10000:65000 -j ACCEPT" \
      "  4. Написать тикет хостеру — canal anti-DDoS на их уровне" \
      "  5. Смена IP в панели хостера — быстрый workaround"
  fi

  # Cleanup
  rm -f "${DUMP}"

  echo
  echo -e "${B}════════════════════════════════════════════════${NC}"
  echo -e "${B}Отчёт завершён. Сохранить лог:${NC}"
  echo -e "${B}  sudo bash $0 > /tmp/attack-$(date +%H%M).log${NC}"
