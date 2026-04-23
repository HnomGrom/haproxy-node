# haproxy-node — API Reference

Полный справочник REST API сервиса `haproxy-node`.

- **Base URL**: `http://<host>:${PORT}` (по умолчанию `http://localhost:3000`)
- **Auth**: все endpoint'ы требуют заголовок `x-api-key: $API_KEY`
  (значение из `.env` → `API_KEY`). Отсутствие или неверный ключ → `401 Unauthorized`.
- **Content-Type**: `application/json` для всех POST/PUT
- **Body limit**: 50 MB (настроено в `main.ts` для bulk-lockdown payload'ов)

---

## Содержание

1. [Общие коды ошибок](#общие-коды-ошибок)
2. [Servers API](#servers-api)
   - [GET /servers](#get-servers)
   - [POST /servers](#post-servers)
   - [DELETE /servers/:id](#delete-serversid)
3. [Lockdown API](#lockdown-api)
   - [GET /lockdown/status](#get-lockdownstatus)
   - [GET /lockdown/ips](#get-lockdownips)
   - [POST /lockdown/ips/add](#post-lockdownipsadd)
   - [POST /lockdown/ips/remove](#post-lockdownipsremove)
   - [POST /lockdown/on](#post-lockdownon)
   - [POST /lockdown/off](#post-lockdownoff)
4. [Модели и DTO](#модели-и-dto)
5. [Сводная таблица endpoints](#сводная-таблица-endpoints)
6. [Environment variables](#environment-variables)

---

## Общие коды ошибок

| Code | Причина | Body |
|---|---|---|
| `200 OK` | Успех | зависит от endpoint'а |
| `400 Bad Request` | Валидация DTO не прошла, или логическая ошибка (пустой `ips[]` в `/lockdown/on`, сервер не найден, HAProxy-конфиг невалиден) | `{ "statusCode": 400, "message": string \| string[], "error": "Bad Request" }` |
| `401 Unauthorized` | Нет или неверный `x-api-key` | `{ "statusCode": 401, "message": "Invalid API key" }` |
| `413 Payload Too Large` | Тело > 50 MB | строковый ответ Express |
| `500 Internal Server Error` | Shell-ошибка (`ipset`/`iptables` упал), БД-ошибка | `{ "statusCode": 500, "message": "..." }` |

---

## Servers API

Управление backend-серверами. HAProxy-конфиг перегенерируется и перезагружается
при каждом create/delete. Если `haproxy -c` не проходит — изменения откатываются
(и в БД, и в конфиге), в ответ идёт `400`.

### `GET /servers`

Список всех зарегистрированных серверов.

**Request**:
```http
GET /servers HTTP/1.1
x-api-key: $API_KEY
```

**Response** — `200 OK`:
```ts
Server[]
```

Пример:
```json
[
  {
    "id": 1,
    "name": "node_a3f1b2c9",
    "ip": "178.253.42.47",
    "backendPort": 443,
    "frontendPort": 10000,
    "createdAt": "2026-04-23T12:00:00.000Z"
  }
]
```

**curl**:
```bash
curl -H "x-api-key: $API_KEY" http://localhost:3000/servers
```

---

### `POST /servers`

Добавить сервер. Автоматически выделяется `frontendPort` из диапазона
`FRONTEND_PORT_MIN..FRONTEND_PORT_MAX`. `name` генерится как `node_` + 4 байта hex.

**Request body** — `CreateServerDto`:
```ts
{
  ip: string           // IPv4 (валидация @IsIP())
  backendPort: number  // целое, 1..65535
}
```

```http
POST /servers HTTP/1.1
x-api-key: $API_KEY
Content-Type: application/json

{ "ip": "38.180.122.151", "backendPort": 443 }
```

**Response** — `200 OK`:
```ts
Server
```

Пример:
```json
{
  "id": 2,
  "name": "node_9f8e7d6c",
  "ip": "38.180.122.151",
  "backendPort": 443,
  "frontendPort": 10001,
  "createdAt": "2026-04-23T14:35:00.000Z"
}
```

**Ошибки**:
- `400` — невалидный `ip` / `backendPort` (DTO)
- `400` — `"No available frontend ports"` (диапазон исчерпан)
- `400` — `"Failed to apply HAProxy config — server not added"` (конфиг не применился, запись откачена)

**curl**:
```bash
curl -X POST http://localhost:3000/servers \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"ip":"38.180.122.151","backendPort":443}'
```

---

### `DELETE /servers/:id`

Удалить сервер. HAProxy-конфиг перегенерируется.

**Path params**:
- `id: number` — ID сервера из БД

**Request**:
```http
DELETE /servers/2 HTTP/1.1
x-api-key: $API_KEY
```

**Response** — `200 OK`. Тело пустое (`""`).

**Ошибки**:
- `400` — `"Server with id N not found"`
- `400` — `"Failed to apply HAProxy config — server not removed"` (сервер возвращается в БД)

**curl**:
```bash
curl -X DELETE http://localhost:3000/servers/2 -H "x-api-key: $API_KEY"
```

---

## Lockdown API

On-demand whitelist-защита VLESS-портов (`FRONTEND_PORT_MIN..FRONTEND_PORT_MAX`)
через `ipset vless_lockdown` + `iptables -m set --match-set`.

**Формат записей** (используется во всех `/lockdown/...` endpoint'ах):
- Точный IPv4: `"1.2.3.4"`
- CIDR-диапазон: `"130.0.238.0/24"`, `"10.0.0.0/16"`, `"0.0.0.0/0"`

Regex валидации (в `IpListDto.ips`):
```
/^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\/(?:3[0-2]|[12]?\d))?$/
```

**Нормализация** на уровне `LockdownService`:
- CIDR не на network-boundary (`"130.0.238.1/24"`) автоматически приводится к `"130.0.238.0/24"`
  (иначе `ipset hash:net` отказался бы добавлять запись).
- Leading zeros в октетах (`"001.002.003.004"`) срезаются → `"1.2.3.4"`.
- `"1.2.3.4/32"` эквивалентно `"1.2.3.4"` — после дедупликации остаётся одна запись.

---

### `GET /lockdown/status`

Текущее состояние защиты.

**Request**:
```http
GET /lockdown/status HTTP/1.1
x-api-key: $API_KEY
```

**Response** — `200 OK`:
```ts
{
  enabled: boolean         // есть ли активное match-set правило в iptables
  whitelistSize: number    // число записей в ipset vless_lockdown
  lastEvent: LockdownEvent | null  // последнее событие из БД (или null если истории нет)
}
```

Пример:
```json
{
  "enabled": true,
  "whitelistSize": 12345,
  "lastEvent": {
    "id": 42,
    "action": "enable",
    "source": "api",
    "reason": "DDoS 14:30",
    "ipCount": 12345,
    "createdAt": "2026-04-23T14:30:00.000Z"
  }
}
```

**curl**:
```bash
curl http://localhost:3000/lockdown/status -H "x-api-key: $API_KEY"
```

---

### `GET /lockdown/ips`

Список записей в whitelist (debug).

**Query params**:
- `limit?: number` — максимум записей в ответе. Дефолт `1000`, верхний потолок `100000`.
  Невалидные значения (`limit=abc`, `limit=-5`, `limit=0`) сбрасываются к дефолту.

**Request**:
```http
GET /lockdown/ips?limit=50 HTTP/1.1
x-api-key: $API_KEY
```

**Response** — `200 OK`:
```ts
string[]    // массив точных IP и/или CIDR в том порядке, как их выдаёт ipset list
```

Пример:
```json
["1.2.3.4", "130.0.238.0/24", "10.0.0.0/16"]
```

**curl**:
```bash
curl "http://localhost:3000/lockdown/ips?limit=50" -H "x-api-key: $API_KEY"
```

---

### `POST /lockdown/ips/add`

Incremental добавление IP/CIDR в whitelist. Работает независимо от того,
активен lockdown или нет — именно через этот endpoint `subscription-api`
пушит новые IP в реальном времени при `GET /subscription`.

**Request body** — `IpListDto`:
```ts
{
  ips: string[]     // массив IPv4/CIDR, 1..2_000_000 элементов
  reason?: string   // до 256 символов (в /ips/add игнорируется, но принимается для единообразия)
}
```

```http
POST /lockdown/ips/add HTTP/1.1
x-api-key: $API_KEY
Content-Type: application/json

{ "ips": ["1.2.3.4", "5.6.7.0/24"] }
```

**Response** — `200 OK`:
```ts
{
  requested: number   // сколько элементов прислано в ips[]
  added: number       // фактически добавлено (после нормализации и дедупликации)
  skipped: number     // дубликаты + невалидные (requested − added)
}
```

Пример:
```json
{ "requested": 2, "added": 2, "skipped": 0 }
```

**Ошибки**:
- `400` — невалидная запись в `ips[]`:
  `"Each entry must be IPv4 or CIDR (e.g., \"1.2.3.4\" or \"130.0.238.0/24\")"`
- `400` — `ips[]` пустой (`ArrayMinSize(1)`)
- `400` — `ips[]` длиннее `2_000_000` (`ArrayMaxSize`)

**curl**:
```bash
curl -X POST http://localhost:3000/lockdown/ips/add \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"ips":["1.2.3.4","130.0.238.0/24"]}'
```

---

### `POST /lockdown/ips/remove`

Incremental удаление IP/CIDR. Используется при бане клиента / отзыве подписки.
Отсутствующие в ipset записи молча пропускаются (не 404).

**Request body** — `IpListDto`:
```ts
{
  ips: string[]     // массив IPv4/CIDR
  reason?: string
}
```

```http
POST /lockdown/ips/remove HTTP/1.1
x-api-key: $API_KEY
Content-Type: application/json

{ "ips": ["1.2.3.4"] }
```

**Response** — `200 OK`:
```ts
{
  requested: number
  removed: number   // фактически удалено (отсутствующие в ipset не считаются)
}
```

Пример:
```json
{ "requested": 1, "removed": 1 }
```

**curl**:
```bash
curl -X POST http://localhost:3000/lockdown/ips/remove \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"ips":["1.2.3.4"]}'
```

---

### `POST /lockdown/on`

**Активировать lockdown** со списком разрешённых IP/CIDR одним вызовом.

За один запрос:
1. Atomic swap содержимого ipset (через `ipset restore + swap`, ~1-3 сек на 100k записей).
2. INSERT `match-set`-правила в `iptables INPUT` на `FRONTEND_PORT_MIN..FRONTEND_PORT_MAX`.
3. DELETE общего `ACCEPT`-правила на том же диапазоне (порядок INSERT→DELETE
   исключает окно без ACCEPT).
4. Persist: `ipset save > /etc/ipset.conf` + `netfilter-persistent save`.

**Request body** — `IpListDto`:
```ts
{
  ips: string[]     // ПОЛНЫЙ whitelist — старое содержимое atomically заменяется через swap.
                    // 1..2_000_000 элементов.
  reason?: string   // до 256 символов, пишется в LockdownEvent.reason
}
```

```http
POST /lockdown/on HTTP/1.1
x-api-key: $API_KEY
Content-Type: application/json

{
  "ips": ["130.0.238.0/24", "10.0.0.0/16", "94.77.161.85"],
  "reason": "DDoS detected 14:30"
}
```

**Response** — `200 OK`:
```ts
{
  enabled: boolean        // всегда true в успешном ответе
  whitelistSize: number   // количество уникальных записей после нормализации+дедупликации
}
```

Пример:
```json
{ "enabled": true, "whitelistSize": 3 }
```

**Ошибки**:
- `400` — `ips[]` пустой или после нормализации/валидации пустой:
  `"Empty or all-invalid ips[] — refusing to activate lockdown (would block all clients)"`
  (защита от самоблокировки — активация с пустым whitelist'ом отрезала бы всех клиентов)
- `400` — невалидная запись (см. `/ips/add`)
- `500` — `ipset`/`iptables` недоступны (не установлены, нет root-прав у сервиса)

**curl** (малый список):
```bash
curl -X POST http://localhost:3000/lockdown/on \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"ips":["130.0.238.0/24","1.2.3.4"],"reason":"DDoS 14:30"}'
```

**curl** (большой payload — до 1M записей):
```bash
# Собрать payload из файла one-ip-per-line
(echo -n '{"ips":['; awk '{print "\""$0"\""}' ips.txt | paste -sd,; echo '],"reason":"full sync"}') \
  > /tmp/activate.json

curl -X POST http://localhost:3000/lockdown/on \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  --data-binary @/tmp/activate.json
```

---

### `POST /lockdown/off`

Деактивировать защиту — вернуть общий `ACCEPT` на VLESS-диапазон.
**Содержимое ipset сохраняется** — при следующей атаке можно переиспользовать
его через новый `/lockdown/on` (старое содержимое будет atomically заменено).

**Request body** — `LockdownOffDto`:
```ts
{
  reason?: string   // до 256 символов
}
```

```http
POST /lockdown/off HTTP/1.1
x-api-key: $API_KEY
Content-Type: application/json

{ "reason": "attack ended" }
```

**Response** — `200 OK`:
```ts
{
  enabled: boolean    // всегда false
}
```

Пример:
```json
{ "enabled": false }
```

**curl**:
```bash
curl -X POST http://localhost:3000/lockdown/off \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"reason":"attack ended"}'
```

---

## Модели и DTO

### `Server`

Prisma-модель `Server` (таблица `Server`).

```ts
interface Server {
  id: number            // autoincrement primary key
  name: string          // автогенерится: "node_" + 4 bytes hex, уникальный
  ip: string            // IPv4 backend-сервера
  backendPort: number   // порт xray на backend
  frontendPort: number  // выделенный HAProxy-фронтенд порт (уникальный)
  createdAt: string     // ISO-8601 datetime
}
```

### `LockdownEvent`

Prisma-модель `LockdownEvent` — журнал операций lockdown.

```ts
interface LockdownEvent {
  id: number
  action: 'enable' | 'disable' | 'add' | 'remove'
  source: string        // "api" (всегда в текущей версии)
  reason: string | null // из поля reason в body запроса
  ipCount: number       // сколько IP/CIDR затронуто операцией
  createdAt: string     // ISO-8601 datetime
}
```

### `CreateServerDto`

```ts
import { IsIP, IsInt, Max, Min } from 'class-validator';

class CreateServerDto {
  @IsIP()              // IPv4
  ip: string;

  @IsInt()
  @Min(1)
  @Max(65535)
  backendPort: number;
}
```

### `IpListDto`

Используется в `/lockdown/ips/add`, `/lockdown/ips/remove`, `/lockdown/on`.

```ts
import { ArrayMaxSize, ArrayMinSize, IsArray, IsOptional, IsString, Matches, MaxLength } from 'class-validator';

// IPv4 (1.2.3.4) или IPv4/CIDR mask 0-32 (130.0.238.0/24).
// Network-boundary не проверяется — нормализуется в LockdownService.
export const IP_OR_CIDR_REGEX =
  /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\/(?:3[0-2]|[12]?\d))?$/;

class IpListDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(2_000_000)
  @Matches(IP_OR_CIDR_REGEX, { each: true })
  ips: string[];

  @IsOptional()
  @IsString()
  @MaxLength(256)
  reason?: string;
}
```

### `LockdownOffDto`

Используется в `/lockdown/off`.

```ts
class LockdownOffDto {
  @IsOptional()
  @IsString()
  @MaxLength(256)
  reason?: string;
}
```

---

## Сводная таблица endpoints

| Метод | Путь | Body / Query | Response | Описание |
|---|---|---|---|---|
| `GET` | `/servers` | — | `Server[]` | Список серверов |
| `POST` | `/servers` | `CreateServerDto` | `Server` | Добавить сервер |
| `DELETE` | `/servers/:id` | — | `""` | Удалить сервер |
| `GET` | `/lockdown/status` | — | `{ enabled, whitelistSize, lastEvent }` | Состояние защиты |
| `GET` | `/lockdown/ips` | `?limit=N` | `string[]` | Содержимое whitelist |
| `POST` | `/lockdown/ips/add` | `IpListDto` | `{ requested, added, skipped }` | Incremental add IP/CIDR |
| `POST` | `/lockdown/ips/remove` | `IpListDto` | `{ requested, removed }` | Incremental remove IP/CIDR |
| `POST` | `/lockdown/on` | `IpListDto` | `{ enabled, whitelistSize }` | Активация со списком IP/CIDR |
| `POST` | `/lockdown/off` | `LockdownOffDto` | `{ enabled }` | Деактивация (ipset сохраняется) |

Все endpoint'ы требуют `x-api-key: $API_KEY`.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `file:./dev.db` | Путь к SQLite БД (libsql) |
| `API_KEY` | — | API-key для `x-api-key` заголовка |
| `HAPROXY_CONFIG_PATH` | `/etc/haproxy/haproxy.cfg` | Путь к HAProxy конфигу |
| `PORT` | `3000` | Порт API-сервиса |
| `FRONTEND_PORT_MIN` | `10000` | Нижняя граница диапазона frontend-портов (и lockdown-защиты) |
| `FRONTEND_PORT_MAX` | `65000` | Верхняя граница диапазона |

---

## Как работает Servers API

1. API получает запрос (add/remove server)
2. Обновляется БД (SQLite через Prisma)
3. HAProxy-конфиг перегенерируется из всех серверов в БД
4. Конфиг валидируется (`haproxy -c`)
5. HAProxy перезагружается (`systemctl reload haproxy`)
6. При ошибке применения — конфиг и БД откатываются к прошлому состоянию, возвращается `400`

### Структура HAProxy-конфига

Для каждого сервера генерируется пара frontend + backend:

```
frontend node1_in
    bind *:10000          # auto-generated frontend port
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    default_backend node1

backend node1
    mode tcp
    server s_1 178.253.42.47:443 check inter 30s fall 3 rise 2
```

---

## Как работает Lockdown API

См. подробный архитектурный документ [`LOCKDOWN_WHITELIST.md`](./LOCKDOWN_WHITELIST.md)
и план реализации [`LOCKDOWN_IMPLEMENTATION.md`](./LOCKDOWN_IMPLEMENTATION.md).

Кратко:
- `ipset vless_lockdown` (`hash:net`) хранит разрешённые IP/CIDR
- `iptables` правило `-m set --match-set vless_lockdown src -j ACCEPT`
  на диапазоне `FRONTEND_PORT_MIN..FRONTEND_PORT_MAX`
- `POST /lockdown/on { ips }` делает atomic swap содержимого ipset +
  активацию правила за один вызов
- `POST /lockdown/ips/add` работает независимо — incremental add даже при
  активном lockdown, без перезагрузки правил

---

## Service management

```bash
systemctl status haproxy-node    # статус
systemctl restart haproxy-node   # перезапуск API
journalctl -u haproxy-node -f    # live-логи
```

## Installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnomGrom/haproxy-node/main/install.sh)
```
