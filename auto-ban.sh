#!/usr/bin/env bash
# Auto-ban подозрительных IP которые нагружают канал.
# Баны хранятся в ipset с TTL и автоматически истекают.
#
# Usage:
#   sudo bash auto-ban.sh                    # найти и забанить
#   sudo bash auto-ban.sh --dry-run          # показать кого бы забанил
#   sudo bash auto-ban.sh --unban            # разбанить всех
#   sudo bash auto-ban.sh --install-cron     # поставить в cron каждую минуту
#   sudo bash auto-ban.sh --remove-cron      # убрать из cron
#   sudo bash auto-ban.sh --stats            # показать статистику банов
#
# Опции порогов:
#   --conn N       IP с >N активными TCP = забанить (default: 30)
#   --syn N        IP с >N SYN за sample = забанить (default: 50)
#   --finwait N    IP с >N FIN-WAIT = забанить (slow-attack; default: 15)
#   --net-count N  /24 подсеть с >N атакующими = бан всей подсети (default: 5)
#   --ttl SECS     TTL бана (default: 86400 = 24ч)
#   --sample SECS  длительность tcpdump sample (default: 10)

set +e

# ───── Defaults ─────
# Пороги мягче для production VLESS (mux + NAT клиенты)
THRESHOLD_CONN=80       # 1 клиент с mux = 10-30 коннектов, NAT-сем: 40-60
THRESHOLD_SYN=150       # пик реконнектов при роуминге мобильной сети
THRESHOLD_FINWAIT=50
THRESHOLD_NET=10        # /24 подсеть — нужно много IP чтобы забанить всю
SAMPLE_SECS=10
BAN_TTL=3600            # 1 час вместо 24 — меньше false positive
DRY_RUN=false
UNBAN=false
SHOW_STATS=false
INSTALL_CRON=false
REMOVE_CRON=false

SET_IP="attackers"
SET_NET="attackers_net"
LOG_FILE="/var/log/auto-ban.log"
CRON_ENTRY="* * * * * /usr/local/bin/auto-ban.sh >> ${LOG_FILE} 2>&1"

# ───── Colors ─────
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'
else
  R=''; G=''; Y=''; B=''; NC=''
fi

hdr()  { echo; echo -e "${B}═══ $* ═══${NC}"; }
sub()  { echo -e "${G}--- $* ---${NC}"; }
warn() { echo -e "${Y}⚠ $*${NC}"; }
err()  { echo -e "${R}✗ $*${NC}"; exit 1; }
log()  { echo -e "${G}[+]${NC} $*"; }

# ───── Parse CLI ─────
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift;;
    --unban)         UNBAN=true; shift;;
    --stats)         SHOW_STATS=true; shift;;
    --install-cron)  INSTALL_CRON=true; shift;;
    --remove-cron)   REMOVE_CRON=true; shift;;
    --conn)          THRESHOLD_CONN="$2"; shift 2;;
    --syn)           THRESHOLD_SYN="$2"; shift 2;;
    --finwait)       THRESHOLD_FINWAIT="$2"; shift 2;;
    --net-count)     THRESHOLD_NET="$2"; shift 2;;
    --ttl)           BAN_TTL="$2"; shift 2;;
    --sample)        SAMPLE_SECS="$2"; shift 2;;
    -h|--help)
      head -25 "$0" | tail -24
      exit 0;;
    *) warn "неизвестный флаг: $1"; shift;;
  esac
done

# ───── Root check ─────
[ "$EUID" -eq 0 ] || err "Запусти как root: sudo bash $0"

# ───── Install deps ─────
if ! command -v ipset &>/dev/null; then
  log "Устанавливаю ipset..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset >/dev/null 2>&1
fi
if ! command -v tcpdump &>/dev/null; then
  log "Устанавливаю tcpdump..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null 2>&1
fi

# ───── Header ─────
echo -e "${B}╔════════════════════════════════════════════════╗${NC}"
echo -e "${B}║           AUTO-BAN ATTACKERS                   ║${NC}"
echo -e "${B}║   $(date '+%Y-%m-%d %H:%M:%S')                       ║${NC}"
echo -e "${B}╚════════════════════════════════════════════════╝${NC}"

# ═════════════════════════ Install cron ═════════════════════════
if ${INSTALL_CRON}; then
  hdr "УСТАНОВКА CRON"
  cp "$0" /usr/local/bin/auto-ban.sh 2>/dev/null
  chmod +x /usr/local/bin/auto-ban.sh
  touch "${LOG_FILE}"
  (crontab -l 2>/dev/null | grep -v "auto-ban.sh"; echo "${CRON_ENTRY}") | crontab -
  log "Скрипт скопирован в /usr/local/bin/auto-ban.sh"
  log "Cron установлен: каждую минуту"
  log "Логи:  ${LOG_FILE}"
  echo
  crontab -l | grep auto-ban
  exit 0
fi

if ${REMOVE_CRON}; then
  hdr "УДАЛЕНИЕ CRON"
  crontab -l 2>/dev/null | grep -v "auto-ban.sh" | crontab -
  log "Cron удалён"
  exit 0
fi

# ═════════════════════════ Setup ipsets ═════════════════════════
ipset create ${SET_IP}  hash:ip  timeout ${BAN_TTL} 2>/dev/null
ipset create ${SET_NET} hash:net timeout ${BAN_TTL} 2>/dev/null

# Подключение к iptables (если не прикреплено)
if ! iptables -C INPUT -m set --match-set ${SET_IP} src -j DROP 2>/dev/null; then
  iptables -I INPUT 1 -m set --match-set ${SET_IP} src -j DROP
  log "Привязал ${SET_IP} к INPUT"
fi
if ! iptables -C INPUT -m set --match-set ${SET_NET} src -j DROP 2>/dev/null; then
  iptables -I INPUT 1 -m set --match-set ${SET_NET} src -j DROP
  log "Привязал ${SET_NET} к INPUT"
fi

# ═════════════════════════ Режим --unban ═════════════════════════
if ${UNBAN}; then
  hdr "РАЗБАН ВСЕХ"
  N1=$(ipset list ${SET_IP}  2>/dev/null | awk '/Number of entries/ {print $NF}')
  N2=$(ipset list ${SET_NET} 2>/dev/null | awk '/Number of entries/ {print $NF}')
  ipset flush ${SET_IP}
  ipset flush ${SET_NET}
  ipset save > /etc/ipset.conf 2>/dev/null
  log "Разбанено: ${N1:-0} IP, ${N2:-0} подсетей"
  exit 0
fi

# ═════════════════════════ Режим --stats ═════════════════════════
if ${SHOW_STATS}; then
  hdr "СТАТИСТИКА БАНОВ"
  echo "${SET_IP}:  $(ipset list ${SET_IP} 2>/dev/null | awk '/Number of entries/ {print $NF}') IP забанено"
  echo "${SET_NET}: $(ipset list ${SET_NET} 2>/dev/null | awk '/Number of entries/ {print $NF}') подсетей забанено"
  echo
  sub "Топ-20 забаненных IP (по оставшемуся TTL)"
  ipset list ${SET_IP} 2>/dev/null | awk '/^[0-9]+\./ {print $1, $3}' | head -20
  echo
  sub "Забаненные /24 подсети"
  ipset list ${SET_NET} 2>/dev/null | awk '/^[0-9]+\./ {print $1, $3}' | head -20
  echo
  sub "iptables счётчики дропов"
  iptables -L INPUT -nv --line-numbers 2>/dev/null | grep -E "${SET_IP}|${SET_NET}"
  echo
  if [ -f "${LOG_FILE}" ]; then
    sub "Последние 10 операций из лога"
    tail -10 "${LOG_FILE}"
  fi
  exit 0
fi

# ═════════════════════════ Собрать whitelist (чтобы себя не забанить) ═════════════════════════
WHITELIST=""
for SET in api_whitelist ssh_whitelist whitelist; do
  if ipset list -n 2>/dev/null | grep -qx "${SET}"; then
    ADDS=$(ipset list "${SET}" 2>/dev/null | awk '/^[0-9]+\./ {print $1}' | cut -d/ -f1)
    WHITELIST="${WHITELIST} ${ADDS}"
  fi
done

# КРИТИЧНО: автоматически whitelist'им backend IP из БД через API
# Иначе auto-ban забанит наши собственные Xray-ноды!
# Если API недоступен — НЕ БАНИМ ничего (safety first)
BACKEND_FETCH_OK=true
if [ -f /opt/haproxy-node/.env ]; then
  API_KEY=$(grep "^API_KEY=" /opt/haproxy-node/.env | cut -d'"' -f2)
  API_PORT=$(grep "^PORT=" /opt/haproxy-node/.env | cut -d= -f2)
  if [ -n "${API_KEY}" ] && [ -n "${API_PORT}" ]; then
    # До 3 попыток с паузой — API может стартовать после systemd restart
    BACKEND_IPS=""
    for attempt in 1 2 3; do
      BACKEND_IPS=$(curl -s --max-time 10 --retry 0 \
        -H "x-api-key: ${API_KEY}" \
        "http://127.0.0.1:${API_PORT}/servers" 2>/dev/null | \
        grep -oE '"ip":"[0-9.]+"' | cut -d'"' -f4)
      [ -n "${BACKEND_IPS}" ] && break
      # Проверяем что API вообще ответил (хоть чем-то)
      if curl -s --max-time 3 "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1; then
        # API отвечает но серверов пусто — это нормально
        BACKEND_FETCH_OK=true
        break
      fi
      sleep 2
    done
    if [ -n "${BACKEND_IPS}" ]; then
      WHITELIST="${WHITELIST} ${BACKEND_IPS}"
      log "Backend IP (из БД) добавлены в whitelist: $(echo ${BACKEND_IPS} | tr '\n' ' ')"
    elif ! ${BACKEND_FETCH_OK}; then
      # API полностью недоступен после 3 попыток — это опасно
      # Скорее всего приложение перезапускается — НЕ банить
      warn "API haproxy-node недоступен после 3 попыток — отменяю бан (safety)"
      rm -f "${TCPDUMP_OUT:-}" 2>/dev/null
      exit 0
    fi
  fi
fi

# Локальные IP интерфейсов (свой сервер не банить)
LOCAL_IPS=$(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
WHITELIST="${WHITELIST} ${LOCAL_IPS}"

# Дефолтный шлюз (роутер в подсети)
GATEWAY=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
[ -n "${GATEWAY}" ] && WHITELIST="${WHITELIST} ${GATEWAY}"

# Добавить текущий SSH IP (если из shell)
if [ -n "${SSH_CLIENT:-}" ]; then
  WHITELIST="${WHITELIST} ${SSH_CLIENT%% *}"
fi
# Приватные сети всегда whitelist (см. is_whitelisted)
WHITELIST="${WHITELIST} 127.0.0.1"

is_whitelisted() {
  local ip="$1"
  for w in ${WHITELIST}; do
    [ "${w}" = "${ip}" ] && return 0
  done
  # Приватные сети
  case "${ip}" in
    10.*|192.168.*|127.*) return 0;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;;
  esac
  return 1
}

# ═════════════════════════ 1. IP с >N активными коннектами ═════════════════════════
hdr "1. IP с > ${THRESHOLD_CONN} активными TCP коннектами"
SUSPECTS_CONN=$(
  ss -Hnt 2>/dev/null | \
    awk '{print $5}' | \
    grep -vE '^\[|^$' | \
    cut -d: -f1 | \
    sort | uniq -c | sort -rn | \
    awk -v t=${THRESHOLD_CONN} '$1 > t {print $2}'
)
C1=$(echo "${SUSPECTS_CONN}" | grep -c . 2>/dev/null)
sub "Кандидатов: ${C1}"
if [ "${C1}" -gt 0 ] 2>/dev/null; then
  ss -Hnt 2>/dev/null | awk '{print $5}' | grep -vE '^\[|^$' | cut -d: -f1 | \
    sort | uniq -c | sort -rn | awk -v t=${THRESHOLD_CONN} '$1 > t' | head -15
fi

# ═════════════════════════ 2. IP с >N SYN за sample ═════════════════════════
hdr "2. IP с > ${THRESHOLD_SYN} SYN-пакетов за ${SAMPLE_SECS}s"
IF=$(ip route | awk '/default/ {print $5; exit}')
TCPDUMP_OUT="/tmp/auto-ban-syn.$$"
timeout ${SAMPLE_SECS} tcpdump -nn -i ${IF} \
  '(tcp[tcpflags] & (tcp-syn|tcp-ack) = tcp-syn)' \
  -c 30000 2>/dev/null > "${TCPDUMP_OUT}"

SUSPECTS_SYN=$(
  awk '/IP / {print $3}' "${TCPDUMP_OUT}" | \
    awk -F. 'NF>=4 {print $1"."$2"."$3"."$4}' | \
    sort | uniq -c | sort -rn | \
    awk -v t=${THRESHOLD_SYN} '$1 > t {print $2}'
)
C2=$(echo "${SUSPECTS_SYN}" | grep -c . 2>/dev/null)
sub "Кандидатов: ${C2}"
if [ "${C2}" -gt 0 ] 2>/dev/null; then
  awk '/IP / {print $3}' "${TCPDUMP_OUT}" | \
    awk -F. 'NF>=4 {print $1"."$2"."$3"."$4}' | \
    sort | uniq -c | sort -rn | awk -v t=${THRESHOLD_SYN} '$1 > t' | head -15
fi

# ═════════════════════════ 3. IP в FIN-WAIT (slow-attack) ═════════════════════════
hdr "3. IP с > ${THRESHOLD_FINWAIT} FIN-WAIT коннектами (slow-attack)"
SUSPECTS_FIN=$(
  ss -Hnt state fin-wait-1 state fin-wait-2 2>/dev/null | \
    awk '{print $5}' | grep -vE '^\[|^$' | cut -d: -f1 | \
    sort | uniq -c | sort -rn | \
    awk -v t=${THRESHOLD_FINWAIT} '$1 > t {print $2}'
)
C3=$(echo "${SUSPECTS_FIN}" | grep -c . 2>/dev/null)
sub "Кандидатов: ${C3}"

# ═════════════════════════ 4. /24 подсети (ботнеты с VPS-фарм) ═════════════════════════
hdr "4. /24 подсети с > ${THRESHOLD_NET} атакующими IP"
SUSPECTS_NETS=$(
  awk '/IP / {print $3}' "${TCPDUMP_OUT}" 2>/dev/null | \
    awk -F. 'NF>=4 {print $1"."$2"."$3".0/24"}' | \
    sort | uniq -c | sort -rn | \
    awk -v t=${THRESHOLD_NET} '$1 > t {print $2}'
)
C4=$(echo "${SUSPECTS_NETS}" | grep -c . 2>/dev/null)
sub "Кандидатов /24: ${C4}"
if [ "${C4}" -gt 0 ] 2>/dev/null; then
  awk '/IP / {print $3}' "${TCPDUMP_OUT}" | \
    awk -F. 'NF>=4 {print $1"."$2"."$3".0/24"}' | \
    sort | uniq -c | sort -rn | awk -v t=${THRESHOLD_NET} '$1 > t' | head -10
fi

# ═════════════════════════ Слить кандидатов и забанить ═════════════════════════
ALL_IPS=$(printf '%s\n' ${SUSPECTS_CONN} ${SUSPECTS_SYN} ${SUSPECTS_FIN} | sort -u | grep -v '^$')
ALL_NETS=$(printf '%s\n' ${SUSPECTS_NETS} | sort -u | grep -v '^$')

hdr "РЕЗУЛЬТАТ"
TOTAL_IPS=$(echo "${ALL_IPS}" | grep -c .)
TOTAL_NETS=$(echo "${ALL_NETS}" | grep -c .)
echo "Всего уникальных IP-кандидатов:     ${TOTAL_IPS}"
echo "Всего уникальных /24 кандидатов:    ${TOTAL_NETS}"

if ${DRY_RUN}; then
  warn "DRY-RUN — никого не баню"
  echo
  sub "Кандидаты IP (до 20):"
  echo "${ALL_IPS}" | head -20
  echo
  sub "Кандидаты /24 (до 10):"
  echo "${ALL_NETS}" | head -10
  rm -f "${TCPDUMP_OUT}"
  exit 0
fi

# Реальный бан
BANNED_IPS=0
SKIPPED_IPS=0
for ip in ${ALL_IPS}; do
  [ -z "${ip}" ] && continue
  if is_whitelisted "${ip}"; then
    SKIPPED_IPS=$((SKIPPED_IPS + 1))
    continue
  fi
  if ipset add ${SET_IP} "${ip}" timeout ${BAN_TTL} 2>/dev/null; then
    BANNED_IPS=$((BANNED_IPS + 1))
  fi
done

BANNED_NETS=0
for net in ${ALL_NETS}; do
  [ -z "${net}" ] && continue
  # Skip подсети которые содержат наш whitelist
  SKIP=false
  for w in ${WHITELIST}; do
    NET_PREFIX=$(echo "${net}" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."}')
    W_PREFIX=$(echo "${w}" | awk -F. '{print $1"."$2"."$3"."}')
    if [ "${NET_PREFIX}" = "${W_PREFIX}" ]; then
      SKIP=true
      break
    fi
  done
  ${SKIP} && continue
  if ipset add ${SET_NET} "${net}" timeout ${BAN_TTL} 2>/dev/null; then
    BANNED_NETS=$((BANNED_NETS + 1))
  fi
done

log "Забанено IP:        ${BANNED_IPS} (пропущено whitelist: ${SKIPPED_IPS})"
log "Забанено подсетей:  ${BANNED_NETS}"

# Persistence
ipset save > /etc/ipset.conf 2>/dev/null
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1

# Cleanup
rm -f "${TCPDUMP_OUT}"

# ═════════════════════════ Итоговая статистика ═════════════════════════
hdr "ТЕКУЩИЕ БАНЫ"
TOTAL_BAN_IPS=$(ipset list ${SET_IP} 2>/dev/null | awk '/Number of entries/ {print $NF}')
TOTAL_BAN_NETS=$(ipset list ${SET_NET} 2>/dev/null | awk '/Number of entries/ {print $NF}')
echo "Всего в ${SET_IP}:  ${TOTAL_BAN_IPS:-0}"
echo "Всего в ${SET_NET}: ${TOTAL_BAN_NETS:-0}"

DROPPED=$(iptables -L INPUT -nv 2>/dev/null | grep -E "${SET_IP}|${SET_NET}" | awk '{s+=$1} END {print s}')
echo "iptables задропало через ipset: ${DROPPED:-0} пакетов"

echo
log "Готово. Разбан: sudo bash $0 --unban"
log "Автобан cron: sudo bash $0 --install-cron"
