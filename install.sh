#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/haproxy-node"
REPO_URL="https://github.com/HnomGrom/haproxy-node.git"
# Ветка по умолчанию — main. Переопределяется env-переменной (REPO_BRANCH или
# короткий alias BRANCH) либо интерактивным prompt'ом ниже.
# Примеры:
#   REPO_BRANCH=develop bash install.sh
#   BRANCH=develop bash install.sh
REPO_BRANCH_DEFAULT="${REPO_BRANCH:-${BRANCH:-main}}"
SERVICE_NAME="haproxy-node"
NODE_MAJOR=22

# ───────────────────────── Colors ─────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ───────────────────────── Root check ─────────────────────
[[ $EUID -eq 0 ]] || err "Run this script as root: sudo bash install.sh"

# ───────────────────────── OS check ───────────────────────
if ! command -v apt-get &>/dev/null; then
  err "This script supports Debian/Ubuntu only"
fi

# ───────────────────────── Prompt config ──────────────────
# -s: ключ не печатается в терминале (история, scrollback, screen-recording).
# Пустая строка после prompt'а компенсирует отсутствие \n при -s.
read -rsp "API key for the service: " API_KEY
echo
[[ -n "$API_KEY" ]] || err "API key cannot be empty"
[[ ${#API_KEY} -ge 8 ]] || err "API key must be ≥8 characters (Joi-валидация на старте сервиса требует это же)"

read -rp "API port [3000]: " API_PORT
API_PORT="${API_PORT:-3000}"

read -rp "Frontend port range min [10000]: " PORT_MIN
PORT_MIN="${PORT_MIN:-10000}"

read -rp "Frontend port range max [65000]: " PORT_MAX
PORT_MAX="${PORT_MAX:-65000}"

read -rp "Git branch [${REPO_BRANCH_DEFAULT}]: " REPO_BRANCH
REPO_BRANCH="${REPO_BRANCH:-${REPO_BRANCH_DEFAULT}}"

# IP, которым разрешён доступ к API (:${API_PORT}) через запятую.
# Пусто = API ЗАКРЫТ (только с localhost).
read -rp "IPv4 (через запятую) с доступом к API [пусто = закрыт]: " API_ALLOWED_IPS
read -rp "IPv6 (через запятую) с доступом к API [пусто = нет]: " API_ALLOWED_IPS_V6

# IP, которым разрешён SSH. Пусто = все (с rate-limit 4/мин).
read -rp "IPv4 (через запятую) с доступом к SSH :22 [пусто = все]: " SSH_ALLOWED_IPS
read -rp "IPv6 (через запятую) с доступом к SSH [пусто = все]: " SSH_ALLOWED_IPS_V6

# Защита от самоблокировки: автоматически добавить текущий SSH IP
# (в IPv4 или IPv6 whitelist — в зависимости от протокола текущей сессии)
CUR_SSH_IP=""
if [ -n "${SSH_CLIENT:-}" ]; then
  CUR_SSH_IP="${SSH_CLIENT%% *}"
elif [ -n "${SSH_CONNECTION:-}" ]; then
  CUR_SSH_IP="${SSH_CONNECTION%% *}"
fi

if [ -n "${CUR_SSH_IP}" ]; then
  if [[ "${CUR_SSH_IP}" == *:* ]]; then
    # IPv6
    if [ -n "${SSH_ALLOWED_IPS_V6}" ] && ! echo ",${SSH_ALLOWED_IPS_V6}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv6 SSH в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6},${CUR_SSH_IP}"
    fi
  else
    # IPv4
    if [ -n "${SSH_ALLOWED_IPS}" ] && ! echo ",${SSH_ALLOWED_IPS}," | grep -q ",${CUR_SSH_IP},"; then
      warn "Автодобавление текущего IPv4 SSH в whitelist: ${CUR_SSH_IP}"
      SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS},${CUR_SSH_IP}"
    fi
  fi
fi

# ───────────────────────── Install system deps ────────────
log "Updating packages..."
apt-get update -qq

log "Installing HAProxy and Git..."
apt-get install -y -qq haproxy curl git

# ───────────────────────── Install Node.js ────────────────
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt $NODE_MAJOR ]]; then
  log "Installing Node.js ${NODE_MAJOR}.x..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
else
  log "Node.js $(node -v) already installed"
fi

# ───────────────────────── Clone project ──────────────────
if [[ -d "$APP_DIR/.git" ]]; then
  log "Updating existing installation (branch: ${REPO_BRANCH})..."
  cd "$APP_DIR"
  git fetch --all --prune || true
  # Если нужная ветка уже локально — switch, иначе создаём локальную от origin/<branch>
  # err при failure: продолжать install на старой ветке тихо опасно (можно
  # незаметно остаться на устаревшем коде).
  if git show-ref --verify --quiet "refs/heads/${REPO_BRANCH}"; then
    git checkout "${REPO_BRANCH}" || err "git checkout ${REPO_BRANCH} failed (есть локальные изменения? разреши вручную)"
  else
    git checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}" || err "branch ${REPO_BRANCH} not found on remote"
  fi
  git pull --ff-only origin "${REPO_BRANCH}" || err "git pull failed (divergent history — разреши вручную)"
else
  log "Cloning repository (branch: ${REPO_BRANCH})..."
  rm -rf "$APP_DIR"
  git clone --branch "${REPO_BRANCH}" "$REPO_URL" "$APP_DIR" || \
    err "git clone failed — ветка '${REPO_BRANCH}' существует в ${REPO_URL}?"
  cd "$APP_DIR"
fi

# ───────────────────────── Create .env ────────────────────
log "Writing .env..."
# umask 077 → файл создаётся с 0600 (rw-------). Без этого default umask 022
# даёт 0644 и API_KEY читаем любым пользователем системы.
(umask 077; cat > .env <<EOF
DATABASE_URL="file:./dev.db"
API_KEY="${API_KEY}"
HAPROXY_CONFIG_PATH="/etc/haproxy/haproxy.cfg"
PORT=${API_PORT}
FRONTEND_PORT_MIN=${PORT_MIN}
FRONTEND_PORT_MAX=${PORT_MAX}
API_ALLOWED_IPS="${API_ALLOWED_IPS}"
API_ALLOWED_IPS_V6="${API_ALLOWED_IPS_V6}"
SSH_ALLOWED_IPS="${SSH_ALLOWED_IPS}"
SSH_ALLOWED_IPS_V6="${SSH_ALLOWED_IPS_V6}"
EOF
)
chown root:root .env
chmod 600 .env

# ───────────────────────── Install & build ────────────────
log "Installing npm dependencies..."
cd "${APP_DIR}" && NODE_ENV=development npm install

log "Generating Prisma client..."
cd "${APP_DIR}" && npx prisma generate

log "Syncing database schema..."
# ВАЖНО: используем `db push`, а не `migrate deploy`.
#
# Причина: `migrate deploy` применяет ТОЛЬКО миграции, закоммиченные в git
# (prisma/migrations/*). Если в schema.prisma появилась модель, но соответствующая
# миграция не закоммичена — таблица в проде не будет создана. Например, раньше
# при добавлении LockdownEvent таблица не создавалась и /lockdown/on падал с
# "no such table: LockdownEvent".
#
# `db push` читает schema.prisma напрямую и приводит БД в соответствие —
# идемпотентно, безопасно для additive-изменений. --accept-data-loss нужен
# чтобы скрипт не висел на prompt'е, если бы вдруг потребовалось удалить столбец.

# Pre-check: новый @@unique([ip, backendPort]) constraint в Server упадёт,
# если в существующей БД уже есть дубли (тот самый legacy-баг — два сервера
# с одинаковым IP). Detect & report ДО `db push` — иначе оператор получит
# непонятный "UNIQUE constraint failed" без указания на конкретные строки.
if [ -f "${APP_DIR}/dev.db" ] && command -v sqlite3 &>/dev/null; then
  DUPS=$(sqlite3 "${APP_DIR}/dev.db" "SELECT ip, backendPort, COUNT(*) c FROM Server GROUP BY ip, backendPort HAVING c > 1;" 2>/dev/null || true)
  if [ -n "${DUPS}" ]; then
    warn "В БД найдены дубликаты (ip, backendPort) — миграция упадёт на @@unique:"
    echo "${DUPS}" | sed 's/^/    /'
    err "Удали дубли вручную: sqlite3 ${APP_DIR}/dev.db \"DELETE FROM Server WHERE id NOT IN (SELECT MIN(id) FROM Server GROUP BY ip, backendPort);\""
  fi
fi

cd "${APP_DIR}" && npx prisma db push --accept-data-loss \
  || err "Prisma db push failed — БД схема не синхронизирована с schema.prisma"

log "Building application..."
cd "${APP_DIR}"
rm -rf "${APP_DIR}/dist"
./node_modules/.bin/tsc -p tsconfig.build.json || err "TypeScript compilation failed"
[[ -f "${APP_DIR}/dist/src/main.js" ]] || err "Build failed — dist/src/main.js not found"
log "Build successful"

# ───────────────────────── HAProxy initial config ─────────
if [[ ! -f /etc/haproxy/haproxy.cfg.original ]]; then
  log "Backing up original HAProxy config..."
  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.original
fi

log "Writing initial HAProxy config..."
cat > /etc/haproxy/haproxy.cfg <<HAPCFG
global
    log /dev/log local0
    maxconn 50000
    daemon

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    timeout client-fin 30s
    timeout server-fin 30s
HAPCFG

systemctl enable haproxy
systemctl restart haproxy

# ───────────────────────── Kernel tuning (sysctl) ─────────
log "Applying kernel DDoS protection (sysctl)..."
cat > /etc/sysctl.d/99-haproxy-ddos.conf <<'SYSCTL'
# SYN-flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2

# Conntrack под нагрузку (4M записей)
net.netfilter.nf_conntrack_max = 4194304
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5

# TCP tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_keepalive_time = 300

# BBR для мобильных
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
SYSCTL

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || warn "sysctl --system returned non-zero (non-fatal)"

# ───────────────────────── Cleanup legacy NAT fallback ────
# Раньше трафик на неизвестные порты редиректился на FALLBACK_PORT через NAT —
# это делало HAProxy мишенью для сканеров. Теперь неизвестные порты дропаются
# policy INPUT DROP. Чистим старую цепочку если осталась.
log "Removing legacy NAT fallback chain (if exists)..."
iptables -w 5 -t nat -D PREROUTING -p tcp -j HAPROXY_FALLBACK 2>/dev/null || true
iptables -w 5 -t nat -F HAPROXY_FALLBACK 2>/dev/null || true
iptables -w 5 -t nat -X HAPROXY_FALLBACK 2>/dev/null || true

# ───────────────────────── Install ipset + persistence ───
# ipset нужен всегда (для vless_lockdown + api/ssh whitelist).
# ipset-persistent — плагин netfilter-persistent, читает /etc/ipset.conf
# при boot ДО iptables-restore (иначе правила с match-set ссылаются на
# несуществующие set'ы и iptables-restore падает).
if ! command -v ipset &>/dev/null; then
  log "Installing ipset + ipset-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset ipset-persistent >/dev/null 2>&1 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset >/dev/null
fi
# ipset-persistent отдельно — пакет мог быть не установлен на уже
# существующем сервере с ipset.
if ! dpkg -s ipset-persistent >/dev/null 2>&1; then
  log "Installing ipset-persistent (plugin for netfilter-persistent)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset-persistent >/dev/null 2>&1 || \
    warn "ipset-persistent package not available — ipsets могут не восстановиться после reboot"
fi

# ───────────────────────── ipset helpers ────────────────────
# Пересоздать set, если он существует с НЕправильным типом или family.
# `ipset create -exist` молча оставляет старый type/family — в результате
# `ipset add CIDR` падает Syntax error на set'ах с hash:ip.
# Аргументы: $1=name $2=expected-type $3=expected-family ($4...)=create-args
ensure_ipset() {
  local name="$1" expected_type="$2" expected_family="$3"
  shift 3
  local actual_type actual_family
  actual_type=$(ipset list "$name" 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}' || true)
  # Header line: "Header: family inet hashsize 65536 maxelem ...". Без -F
  # awk использует whitespace, $2="family" $3="inet". С -F': ' family-token
  # сидит внутри $2 и не извлекается прямым $(i+1).
  actual_family=$(ipset list "$name" 2>/dev/null | awk '/^Header/ {for(i=1;i<=NF;i++) if($i=="family") {print $(i+1); exit}}' || true)
  if [ -n "$actual_type" ] && { [ "$actual_type" != "$expected_type" ] || \
       { [ -n "$actual_family" ] && [ "$actual_family" != "$expected_family" ]; }; }; then
    warn "  ipset $name has type=$actual_type family=$actual_family (expected $expected_type/$expected_family) — recreating"
    ipset destroy "$name" 2>/dev/null || true
  fi
  ipset create "$name" "$@" -exist
}

# ───────────────────────── API whitelist (ipset) ──────────
if [ -n "${API_ALLOWED_IPS}" ]; then
  log "Configuring API whitelist for :${API_PORT}..."
  # `-i lo -j ACCEPT` уже покрывает loopback — не дублируем 127.0.0.1 в set.
  ensure_ipset api_whitelist hash:net inet hash:net family inet maxelem 128
  ipset flush api_whitelist
  IFS=',' read -ra _IPS <<< "${API_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${_IPS[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add api_whitelist "$ip" 2>/dev/null; then
      log "  + API allow: $ip"
    else
      warn "  ? invalid/duplicate: $ip"
    fi
  done
fi

# ───────────────────────── SSH whitelist (ipset) ──────────
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  log "Configuring SSH whitelist for :22..."
  ensure_ipset ssh_whitelist hash:net inet hash:net family inet maxelem 128
  ipset flush ssh_whitelist
  IFS=',' read -ra _IPS <<< "${SSH_ALLOWED_IPS//[[:space:]]/}"
  for ip in "${_IPS[@]}"; do
    [ -z "$ip" ] && continue
    if ipset add ssh_whitelist "$ip" 2>/dev/null; then
      log "  + SSH allow: $ip"
    else
      warn "  ? invalid/duplicate: $ip"
    fi
  done
fi

# ───────────────────────── INPUT Lockdown (policy DROP) ───
log "Lockdown: rebuilding INPUT chain with policy DROP..."

# Backup текущих правил перед flush — operator-safe re-install. Сохраняем
# отдельно от netfilter-persistent (rules.v4), чтобы можно было вернуть
# именно "до запуска install.sh" состояние.
BACKUP_TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /root/.haproxy-node-backups
iptables-save > "/root/.haproxy-node-backups/iptables.${BACKUP_TS}" 2>/dev/null || true
log "  iptables backup: /root/.haproxy-node-backups/iptables.${BACKUP_TS}"

# Policy ACCEPT перед flush — не разрываем SSH при переустановке.
# `-w 5` ждёт xtables-lock до 5с (избегаем race с fail2ban/docker).
iptables -w 5 -P INPUT ACCEPT
iptables -w 5 -P FORWARD ACCEPT
iptables -w 5 -F INPUT

# 1. Loopback + ESTABLISHED/INVALID
iptables -w 5 -A INPUT -i lo -j ACCEPT
iptables -w 5 -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w 5 -A INPUT -m conntrack --ctstate INVALID -j DROP

# 2. SSH — whitelist или rate-limit
if [ -n "${SSH_ALLOWED_IPS}" ]; then
  iptables -w 5 -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist src -j ACCEPT
  log "  ACCEPT :22 только для ssh_whitelist"
else
  iptables -w 5 -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --set --name SSH --rsource
  iptables -w 5 -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP
  iptables -w 5 -A INPUT -p tcp --dport 22 -j ACCEPT
  log "  ACCEPT :22 всем с rate-limit (4/60s)"
fi

# 3. API — только для api_whitelist
if [ -n "${API_ALLOWED_IPS}" ]; then
  iptables -w 5 -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist src -j ACCEPT
  log "  ACCEPT :${API_PORT} только для api_whitelist"
else
  warn "  :${API_PORT} API ЗАКРЫТ (нет API_ALLOWED_IPS)"
fi

# 4. VLESS frontend-диапазон
iptables -w 5 -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

# 5. ICMP с rate-limit
iptables -w 5 -A INPUT -p icmp -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# 6. Policy DROP — всё остальное в чёрную дыру
iptables -w 5 -P INPUT DROP
iptables -w 5 -P FORWARD DROP
iptables -w 5 -P OUTPUT ACCEPT

log "INPUT policy DROP активна. Открыто: :22, :${PORT_MIN}-${PORT_MAX}"
[ -n "${API_ALLOWED_IPS}" ] && log "  + :${API_PORT} для whitelist"

# Раннее сохранение: если любой из блоков ниже (IPv6, vless_lockdown type-check)
# прервётся с ошибкой — хотя бы сам firewall уже залит на диск. Иначе после
# reboot восстановится старое состояние (возможно policy ACCEPT), а мы снова
# окажемся без защиты. Финальное `netfilter-persistent save` в конце всё равно
# перезапишет это актуальными правилами.
#
# Атомарная запись через tmp+rename: при SIGKILL/ENOSPC/OOM прямой `>` оставит
# усечённый файл, и iptables-restore при boot'е упадёт.
mkdir -p /etc/iptables
TMP_V4=$(mktemp /etc/iptables/rules.v4.XXXXXX)
if iptables-save > "$TMP_V4" 2>/dev/null && [ -s "$TMP_V4" ]; then
  mv "$TMP_V4" /etc/iptables/rules.v4
else
  rm -f "$TMP_V4"
  warn "iptables-save (early) failed — rules.v4 не обновлён"
fi

# ───────────────────────── IPv6 Lockdown ──────────────────
IPV6_ENABLED=false
if command -v ip6tables &>/dev/null && ip6tables -S INPUT &>/dev/null; then
  IPV6_ENABLED=true
fi

if [ "${IPV6_ENABLED}" = "true" ]; then
  log "IPv6 активен — применяю lockdown ip6tables..."

  # Backup существующих v6-правил
  ip6tables-save > "/root/.haproxy-node-backups/ip6tables.${BACKUP_TS}" 2>/dev/null || true

  # API v6 whitelist
  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    # `-i lo -j ACCEPT` уже покрывает ::1 — не дублируем в set.
    ensure_ipset api_whitelist6 hash:net inet6 hash:net family inet6 maxelem 128
    ipset flush api_whitelist6
    IFS=',' read -ra _IPS <<< "${API_ALLOWED_IPS_V6//[[:space:]]/}"
    for ip in "${_IPS[@]}"; do
      [ -z "$ip" ] && continue
      ipset add api_whitelist6 "$ip" 2>/dev/null && log "  + API v6 allow: $ip" || warn "  ? bad v6: $ip"
    done
  fi

  # SSH v6 whitelist
  if [ -n "${SSH_ALLOWED_IPS_V6}" ]; then
    ensure_ipset ssh_whitelist6 hash:net inet6 hash:net family inet6 maxelem 128
    ipset flush ssh_whitelist6
    IFS=',' read -ra _IPS <<< "${SSH_ALLOWED_IPS_V6//[[:space:]]/}"
    for ip in "${_IPS[@]}"; do
      [ -z "$ip" ] && continue
      ipset add ssh_whitelist6 "$ip" 2>/dev/null && log "  + SSH v6 allow: $ip" || warn "  ? bad v6: $ip"
    done
  fi

  # vless_lockdown6 ipset (hash:net family inet6) — match-set на VLESS-портах
  # для IPv6. Без этого set'а ip6tables -m set --match-set падает и lockdown
  # для IPv6 неактивен → атака идёт через v6 мимо IPv4 защиты.
  # ensure_ipset снимет ip6tables match-set правило (если есть) и пересоздаст
  # set если type/family не совпадает.
  EXISTING_TYPE6=$(ipset list vless_lockdown6 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}' || true)
  if [ -n "$EXISTING_TYPE6" ] && [ "$EXISTING_TYPE6" != "hash:net" ]; then
    ip6tables -w 5 -D INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
      -m set --match-set vless_lockdown6 src -j ACCEPT 2>/dev/null || true
  fi
  ensure_ipset vless_lockdown6 hash:net inet6 hash:net family inet6 maxelem 1000000 hashsize 65536

  # Policy ACCEPT перед flush — не разрываем IPv6 SSH при переустановке
  ip6tables -w 5 -P INPUT ACCEPT
  ip6tables -w 5 -P FORWARD ACCEPT
  ip6tables -w 5 -F INPUT

  # 1. Loopback + ESTABLISHED/INVALID
  ip6tables -w 5 -A INPUT -i lo -j ACCEPT
  ip6tables -w 5 -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -w 5 -A INPUT -m conntrack --ctstate INVALID -j DROP

  # 2. ICMPv6 — КРИТИЧНО, без этого IPv6 сеть сломается (NDP/RA/PMTU)
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type neighbor-solicitation -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type neighbor-advertisement -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
  # echo-request (ping6) — с rate-limit
  ip6tables -w 5 -A INPUT -p ipv6-icmp --icmpv6-type echo-request -m limit --limit 5/s -j ACCEPT

  # 3. SSH — whitelist или rate-limit
  if [ -n "${SSH_ALLOWED_IPS_V6}" ]; then
    ip6tables -w 5 -A INPUT -p tcp --dport 22 -m set --match-set ssh_whitelist6 src -j ACCEPT
    log "  ACCEPT :22 (v6) только для ssh_whitelist6"
  else
    ip6tables -w 5 -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --set --name SSH6 --rsource
    ip6tables -w 5 -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
      -m recent --update --seconds 60 --hitcount 4 --name SSH6 --rsource -j DROP
    ip6tables -w 5 -A INPUT -p tcp --dport 22 -j ACCEPT
    log "  ACCEPT :22 (v6) всем с rate-limit (4/60s)"
  fi

  # 4. API v6 — только для api_whitelist6
  if [ -n "${API_ALLOWED_IPS_V6}" ]; then
    ip6tables -w 5 -A INPUT -p tcp --dport ${API_PORT} -m set --match-set api_whitelist6 src -j ACCEPT
    log "  ACCEPT :${API_PORT} (v6) только для api_whitelist6"
  fi

  # 5. VLESS frontend-диапазон — ACCEPT по умолчанию (lockdown.service.ts
  # сам поднимет match-set vless_lockdown6 правило ПЕРЕД этим ACCEPT
  # при enable() и снимет это ACCEPT, если активен lockdown).
  ip6tables -w 5 -A INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} -j ACCEPT

  # 6. Policy DROP
  ip6tables -w 5 -P INPUT DROP
  ip6tables -w 5 -P FORWARD DROP
  ip6tables -w 5 -P OUTPUT ACCEPT

  log "IPv6 INPUT policy DROP активна (lockdown6 ipset готов)"

  # Раннее сохранение v6 (см. комментарий у IPv4 выше) — atomic.
  TMP_V6=$(mktemp /etc/iptables/rules.v6.XXXXXX)
  if ip6tables-save > "$TMP_V6" 2>/dev/null && [ -s "$TMP_V6" ]; then
    mv "$TMP_V6" /etc/iptables/rules.v6
  else
    rm -f "$TMP_V6"
    warn "ip6tables-save (early) failed — rules.v6 не обновлён"
  fi
else
  warn "IPv6 не активен на сервере (ip6tables недоступен) — пропускаю IPv6 защиту"
fi

# ───────────────────────── Lockdown ipset (vless_lockdown) ─
# Pre-create set с hash:net (поддерживает точные IP + CIDR-диапазоны).
# Параметры должны совпадать с src/lockdown/lockdown.service.ts (MAX_ELEM, HASH_SIZE).
log "Ensuring vless_lockdown ipset (hash:net)..."

# `|| true` в конце pipe'а — защита от `set -e`:
#   1. На чистой установке `ipset list vless_lockdown` возвращает exit=1 (set'а нет).
#   2. `awk '... exit'` останавливает обработку после первого совпадения —
#      без `head -n1`, который провоцирует SIGPIPE и exit=141 под pipefail.
EXISTING_TYPE=$(ipset list vless_lockdown 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}' || true)
if [ -n "$EXISTING_TYPE" ] && [ "$EXISTING_TYPE" != "hash:net" ]; then
  # Снять iptables-правила, ссылающиеся на set (иначе destroy падает "in use")
  iptables -w 5 -D INPUT -p tcp -m multiport --dports ${PORT_MIN}:${PORT_MAX} \
    -m set --match-set vless_lockdown src -j ACCEPT 2>/dev/null || true
fi
ensure_ipset vless_lockdown hash:net inet hash:net maxelem 1000000 hashsize 65536 family inet

FINAL_TYPE=$(ipset list vless_lockdown | awk -F': ' '/^Type/ {print $2; exit}' || true)
if [ "$FINAL_TYPE" != "hash:net" ]; then
  err "vless_lockdown has type '$FINAL_TYPE', expected hash:net"
fi

# Если в vless_lockdown накопились IP — предыдущая установка имела активный
# lockdown. После flush'а INPUT match-set правило снято, оператор должен
# явно вернуть его через POST /lockdown/on. Ipset-данные сохранены.
LOCKDOWN_SIZE=$(ipset list -t vless_lockdown 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; exit}' | tr -d '[:space:]')
if [[ "${LOCKDOWN_SIZE:-0}" =~ ^[0-9]+$ ]] && [ "${LOCKDOWN_SIZE}" -gt 0 ]; then
  warn "vless_lockdown содержит ${LOCKDOWN_SIZE} записей, но match-set правило снято install.sh-ом"
  warn "  → вызовите POST /lockdown/on с актуальным whitelist'ом, чтобы lockdown снова стал активным"
fi

# ───────────────────────── ipset persistence ──────────────
# Сохранить все ipsets (api_whitelist, ssh_whitelist, vless_lockdown, *6) в
# /etc/ipset.conf через атомарный rename (defense против частичной записи
# при SIGKILL/ENOSPC: на boot'е ipset-persistent читает повреждённый файл,
# падает, и iptables-restore тоже падает на match-set без set'а).
TMP_IPSET=$(mktemp /etc/ipset.conf.XXXXXX)
if ipset save > "$TMP_IPSET" 2>/dev/null && [ -s "$TMP_IPSET" ]; then
  mv "$TMP_IPSET" /etc/ipset.conf
else
  rm -f "$TMP_IPSET"
  warn "ipset save failed — /etc/ipset.conf не обновлён"
fi

# Fallback для старых ifupdown систем (Debian pre-systemd-networkd).
# На современных Ubuntu/netplan не срабатывает — нужен ipset-persistent плагин.
if [ ! -f /etc/network/if-pre-up.d/ipset-restore ]; then
  cat > /etc/network/if-pre-up.d/ipset-restore <<'IPSETR'
#!/bin/sh
[ -f /etc/ipset.conf ] && /sbin/ipset restore < /etc/ipset.conf
exit 0
IPSETR
  chmod +x /etc/network/if-pre-up.d/ipset-restore
fi

# Persist iptables + ip6tables rules across reboots
if ! command -v netfilter-persistent &>/dev/null; then
  log "Installing iptables-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null
fi

# Плагины netfilter-persistent запускаются в алфавитном порядке.
# ipset-plugin (по умолчанию может быть назван 10-ipset / 15-ipset / 25-ipset
# в зависимости от версии пакета ipset-persistent) должен выполниться ДО
# iptables-plugin (типично 15-iptables) и ip6tables-plugin (25-ip6tables),
# иначе iptables-restore падает на правилах с --match-set (set'а ещё нет).
#
# Достаточно поднять только ipset в префикс 05-* — он гарантированно
# выполнится раньше любого *-iptables (минимум 10) и *-ip6tables (минимум 20).
# Переименование iptables/ip6tables плагинов не требуется.
PLUGINS_DIR="/usr/share/netfilter-persistent/plugins.d"
if [ -d "${PLUGINS_DIR}" ]; then
  # ipset-плагин в приоритет — префикс 05
  for p in "${PLUGINS_DIR}"/*-ipset; do
    [ -e "$p" ] || continue
    base=$(basename "$p" | sed -E 's/^[0-9]+-//')
    target="${PLUGINS_DIR}/05-${base}"
    if [ "$p" != "$target" ]; then
      if mv "$p" "$target" 2>/dev/null; then
        log "Moved ipset plugin to 05-${base} (runs before iptables at boot)"
      else
        warn "Не удалось переименовать $p → $target (ipset может загружаться после iptables)"
      fi
    fi
  done
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

# ───────────────────────── Systemd service ────────────────
log "Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=HAProxy Node Management API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(which node) ${APP_DIR}/dist/src/main.js
Restart=on-failure
RestartSec=5
EnvironmentFile=${APP_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# ───────────────────────── Verify service is actually running ─
# Даём sec на старт, потом проверяем состояние. Если сервис упал
# (например из-за сломанной миграции или проблемы с зависимостями) —
# лучше сразу сказать, чем пользователь узнает об этом при первом запросе.
sleep 3
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  log "${SERVICE_NAME} service is ACTIVE"
else
  warn "${SERVICE_NAME} service НЕ активен после старта!"
  warn "  systemctl status ${SERVICE_NAME}"
  warn "  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  echo
  journalctl -u "${SERVICE_NAME}" -n 20 --no-pager 2>/dev/null || true
fi

# ───────────────────────── Smoke-test API ─────────────────
# Проверяем что API отвечает и lockdown-таблица реально создана.
# Здесь ловим именно твою прошлую проблему: если `prisma db push` не
# создал LockdownEvent — запрос к /lockdown/status вернёт 500.
sleep 2
SMOKE=$(curl -sf --max-time 5 -H "x-api-key: ${API_KEY}" \
  "http://127.0.0.1:${API_PORT}/lockdown/status" 2>/dev/null || echo "FAILED")
if echo "${SMOKE}" | grep -q '"enabled"'; then
  log "Smoke-test /lockdown/status: OK"
else
  warn "Smoke-test /lockdown/status FAILED — ответ: ${SMOKE}"
  warn "  Возможные причины: сервис не поднялся, БД схема не синхронизирована, прокси/firewall"
fi

# ───────────────────────── Done ───────────────────────────
log "Installation complete!"
echo ""
echo "  API running on port ${API_PORT}"
echo "  Service:  systemctl status ${SERVICE_NAME}"
echo "  Logs:     journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "  Usage:"
echo "    curl -H 'x-api-key: ${API_KEY}' http://localhost:${API_PORT}/servers"
echo "    curl -H 'x-api-key: ${API_KEY}' http://localhost:${API_PORT}/lockdown/status"
echo ""
