#!/usr/bin/env bash
# Полный health-check сервера: CPU, RAM, диск, сеть, процессы, Docker, логи.
# Ничего не меняет, только читает. Запуск под root даёт больше данных.
#
# Usage:  sudo bash health-check.sh
#         sudo bash health-check.sh > /tmp/health.log 2>&1

set +e  # не падаем на ошибках отдельных команд

# ───── Цвета ─────
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
else
  R=''; G=''; Y=''; B=''; NC=''
fi

hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
sub()  { echo -e "${G}--- $* ---${NC}"; }
warn() { echo -e "${Y}⚠ $*${NC}"; }
err()  { echo -e "${R}✗ $*${NC}"; }

echo -e "${B}╔════════════════════════════════════════════════╗${NC}"
echo -e "${B}║          SERVER HEALTH CHECK                   ║${NC}"
echo -e "${B}║   $(date '+%Y-%m-%d %H:%M:%S')                       ║${NC}"
echo -e "${B}╚════════════════════════════════════════════════╝${NC}"

# ═════════════════════════ 1. СИСТЕМА ═════════════════════════
hdr "1. СИСТЕМА"
echo "hostname:  $(hostname -f 2>/dev/null || hostname)"
echo "kernel:    $(uname -r)"
echo "os:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
echo "uptime:    $(uptime -p 2>/dev/null || uptime)"
echo "users:     $(who | wc -l) онлайн"
echo "date:      $(date)"

# ═════════════════════════ 2. CPU ═════════════════════════
hdr "2. CPU"
CORES=$(nproc 2>/dev/null || echo "?")
echo "cores:     ${CORES}"
echo "model:     $(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
echo
echo "load avg:  $(awk '{print $1, $2, $3}' /proc/loadavg)"
LOAD1=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
if [ "${LOAD1:-0}" -gt "${CORES}" ] 2>/dev/null; then
  warn "load (${LOAD1}) превышает число ядер (${CORES}) — сервер перегружен"
fi
echo

sub "загрузка за 3 секунды (%us=user %sy=system %si=softirq %id=idle)"
if command -v mpstat >/dev/null 2>&1; then
  mpstat 1 3 2>/dev/null | tail -n +4 | awk 'NR==1 || $3=="all"'
else
  top -bn1 | grep -E "^%Cpu|^Cpu" | head -1
fi

echo
sub "топ-10 процессов по CPU"
ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu 2>/dev/null | head -11

# ═════════════════════════ 3. RAM ═════════════════════════
hdr "3. RAM / SWAP"
free -h | head -3
echo
MEM_PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
echo "использовано RAM: ${MEM_PCT}%"
[ "${MEM_PCT:-0}" -gt 85 ] && warn "RAM использована на ${MEM_PCT}% — близко к пределу"

SWAP_USED=$(free | awk '/Swap:/ {print $3}')
if [ "${SWAP_USED:-0}" -gt 0 ]; then
  SWAP_PCT=$(free | awk '/Swap:/ {printf "%.0f", $3/$2*100}')
  echo "используется swap: ${SWAP_PCT}%"
  [ "${SWAP_PCT:-0}" -gt 50 ] && warn "активный свопинг — RAM исчерпывается"
fi

echo
sub "топ-10 процессов по RAM"
ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem 2>/dev/null | head -11

# ═════════════════════════ 4. ДИСК ═════════════════════════
hdr "4. ДИСК"
sub "использование (df -h)"
df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | grep -v "^Filesystem" | \
  awk '{
    use=$5; gsub("%","",use);
    if (use+0 > 90) printf "\033[0;31m[!] %s\033[0m\n", $0;
    else if (use+0 > 75) printf "\033[1;33m[?] %s\033[0m\n", $0;
    else print "    " $0
  }'

echoнап
sub "inodes"
df -hi -x tmpfs -x devtmpfs 2>/dev/null | grep -v "^Filesystem" | head -5

echo
sub "disk I/O (5сек сэмпл)"
if command -v iostat >/dev/null 2>&1; then
  iostat -dx 1 5 2>/dev/null | tail -n +4 | awk '$1 != "" {print}' | tail -20
else
  cat /proc/diskstats 2>/dev/null | awk '$3 !~ /^loop|^ram/ {print $3, "reads:", $4, "writes:", $8}' | head -10
fi

# ═════════════════════════ 5. СЕТЬ ═════════════════════════
hdr "5. СЕТЬ"
IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
echo "default interface: ${IF}"
echo "internal IP:       $(hostname -I 2>/dev/null | tr ' ' '\n' | head -3 | tr '\n' ' ')"
echo

sub "pps / bps (5сек сэмпл на ${IF})"
if [ -n "${IF}" ] && [ -e "/sys/class/net/${IF}/statistics/rx_packets" ]; then
  R1=$(cat /sys/class/net/${IF}/statistics/rx_packets)
  B1=$(cat /sys/class/net/${IF}/statistics/rx_bytes)
  T1=$(cat /sys/class/net/${IF}/statistics/tx_packets)
  TB1=$(cat /sys/class/net/${IF}/statistics/tx_bytes)
  D1=$(cat /sys/class/net/${IF}/statistics/rx_dropped)
  sleep 5
  R2=$(cat /sys/class/net/${IF}/statistics/rx_packets)
  B2=$(cat /sys/class/net/${IF}/statistics/rx_bytes)
  T2=$(cat /sys/class/net/${IF}/statistics/tx_packets)
  TB2=$(cat /sys/class/net/${IF}/statistics/tx_bytes)
  D2=$(cat /sys/class/net/${IF}/statistics/rx_dropped)
  RPPS=$(( (R2-R1)/5 ))
  RMBPS=$(( (B2-B1)*8/5/1024/1024 ))
  TPPS=$(( (T2-T1)/5 ))
  TMBPS=$(( (TB2-TB1)*8/5/1024/1024 ))
  DROPS=$(( D2-D1 ))
  printf "%-5s %-12s %-10s %-12s %-10s %s\n" "" "rx_pps" "rx_mbps" "tx_pps" "tx_mbps" "dropped"
  printf "%-5s %-12s %-10s %-12s %-10s %s\n" "" "${RPPS}" "${RMBPS}" "${TPPS}" "${TMBPS}" "${DROPS}"
  [ "${RPPS}" -gt 50000 ]  && warn "rx_pps высокий (${RPPS}) — возможна атака или пик нагрузки"
  [ "${DROPS}" -gt 100 ]   && warn "интерфейс дропает пакеты (${DROPS}/5s) — перегрузка NIC или rx-buffer"
fi

echo
sub "TCP состояния"
ss -s 2>/dev/null | head -7
echo
ss -Hnt 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

echo
sub "listening ports"
ss -Hnltp 2>/dev/null | awk '{print $4, $6}' | sort -u | head -20

echo
sub "топ-10 источников коннектов (установленных)"
TOP=$(ss -Hnt state established 2>/dev/null | awk '{print $5}' | sed 's/\[.*\]/IPv6/' | cut -d: -f1 | sort | uniq -c | sort -rn | head -10)
if [ -n "${TOP}" ]; then
  echo "${TOP}"
else
  echo "нет установленных коннектов"
fi

echo
sub "conntrack"
if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
  CNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
  MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
  PCT=$((CNT*100/MAX))
  echo "count: ${CNT} / max: ${MAX} (${PCT}%)"
  [ "${PCT}" -gt 80 ] && warn "conntrack близок к переполнению (${PCT}%)"
else
  echo "conntrack не загружен"
fi

# ═════════════════════════ 6. СИСТЕМНЫЕ ЛИМИТЫ ═════════════════════════
hdr "6. СИСТЕМНЫЕ ЛИМИТЫ"
echo "fs.file-max:           $(cat /proc/sys/fs/file-max 2>/dev/null)"
echo "fs.file-nr (alloc):    $(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1, "/", $3}')"
echo "net.core.somaxconn:    $(cat /proc/sys/net/core/somaxconn 2>/dev/null)"
echo "tcp_max_syn_backlog:   $(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null)"
echo "tcp_syncookies:        $(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null) (1 = включены)"
echo "ip_local_port_range:   $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)"

# ═════════════════════════ 7. DOCKER ═════════════════════════
if command -v docker >/dev/null 2>&1; then
  hdr "7. DOCKER"
  CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
  echo "активных контейнеров: ${CONTAINERS}"
  if [ "${CONTAINERS}" -gt 0 ]; then
    echo
    sub "docker ps"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | head -10
    echo
    sub "docker stats (snapshot)"
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}' 2>/dev/null | head -10
  fi
fi

# ═════════════════════════ 8. SYSTEMD ═════════════════════════
hdr "8. SYSTEMD — УПАВШИЕ СЕРВИСЫ"
FAILED=$(systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ "${FAILED}" -gt 0 ]; then
  warn "${FAILED} упавших сервисов:"
  systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null
else
  echo -e "${G}✓ все сервисы работают${NC}"
fi

# ═════════════════════════ 9. IPTABLES / IPSET ═════════════════════════
hdr "9. IPTABLES / IPSET"
if command -v iptables >/dev/null 2>&1; then
  echo "policy INPUT:   $(iptables -S INPUT 2>/dev/null | head -1)"
  echo "правил INPUT:   $(iptables -S INPUT 2>/dev/null | grep -c "^-A")"
  echo "правил FORWARD: $(iptables -S FORWARD 2>/dev/null | grep -c "^-A")"
  echo
  sub "топ-5 правил по дропам (pkts)"
  iptables -L INPUT -nv --line-numbers 2>/dev/null | awk 'NR>2 && $2+0 > 100' | sort -k2 -rn | head -5
fi
if command -v ipset >/dev/null 2>&1; then
  echo
  SETS=$(ipset list -n 2>/dev/null)
  if [ -n "${SETS}" ]; then
    sub "ipset наборы"
    for s in ${SETS}; do
      N=$(ipset list "${s}" 2>/dev/null | grep "Number of entries" | awk '{print $NF}')
      printf "  %-20s  %s записей\n" "${s}" "${N}"
    done
  fi
fi

# ═════════════════════════ 10. ЛОГИ ЯДРА ═════════════════════════
hdr "10. ПОСЛЕДНИЕ ОШИБКИ ЯДРА (dmesg)"
dmesg -T 2>/dev/null | tail -200 | \
  grep -iE "oom|killed|panic|error|fail|conntrack|drop|segfault|overcommit|i/o error" | \
  tail -10 || echo "нет доступа к dmesg (запускать под root)"

# ═════════════════════════ 11. АВТОРИЗАЦИЯ / SSH ═════════════════════════
hdr "11. ПОПЫТКИ ВХОДА (SSH)"
if [ -f /var/log/auth.log ]; then
  FAILS=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null)
  echo "неудачных SSH за сутки: ${FAILS}"
  if [ "${FAILS:-0}" -gt 50 ]; then
    sub "топ-10 IP с brute-force"
    grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -10
  fi
elif command -v journalctl >/dev/null 2>&1; then
  journalctl -u ssh --since "1 day ago" --no-pager 2>/dev/null | grep -c "Failed password" | \
    xargs -I{} echo "неудачных SSH за сутки: {}"
fi

# ═════════════════════════ 12. TOP-5 ДЛИТЕЛЬНО ЖИВУЩИХ ПРОЦЕССОВ ═════════════════════════
hdr "12. ТОП-5 ПРОЦЕССОВ ПО ВРЕМЕНИ CPU"
ps -eo pid,user,etime,time,comm --sort=-time 2>/dev/null | head -6

# ═════════════════════════ ИТОГ ═════════════════════════
echo
echo -e "${B}═══ ИТОГ ═══${NC}"
LOAD_RAW=$(awk '{print $1}' /proc/loadavg)
MEM_RAW=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
DISK_RAW=$(df / | awk 'END {gsub("%",""); print $5}')
TCP_TOTAL=$(ss -Hnt 2>/dev/null | wc -l)

printf "  CPU load:       %s\n"         "${LOAD_RAW}"
printf "  RAM used:       %s%%\n"       "${MEM_RAW}"
printf "  Disk /:         %s%%\n"       "${DISK_RAW}"
printf "  TCP connects:   %s\n"         "${TCP_TOTAL}"
if [ -n "${RPPS:-}" ]; then
  printf "  RX pps / mbps:  %s / %s\n"  "${RPPS}" "${RMBPS}"
  printf "  TX pps / mbps:  %s / %s\n"  "${TPPS}" "${TMBPS}"
fi
printf "  conntrack:      %s / %s\n"    "${CNT:-?}" "${MAX:-?}"

echo
echo -e "${G}✓ health-check завершён${NC}"
echo "полный лог сохранить:  sudo bash $0 > /tmp/health.log 2>&1"
