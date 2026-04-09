# HAProxy Node — API Documentation

## Authentication

All endpoints require the `x-api-key` header.

```
x-api-key: <your-api-key>
```

Missing or invalid key returns `401 Unauthorized`.

---

## Endpoints

### Get all servers

```
GET /servers
```

**Response** `200 OK`

```json
[
  {
    "id": 1,
    "name": "node_a3f1b2c9",
    "ip": "178.253.42.47",
    "backendPort": 443,
    "frontendPort": 10000,
    "createdAt": "2026-04-09T12:00:00.000Z"
  },
  {
    "id": 2,
    "name": "node_d4e5f678",
    "ip": "185.153.183.189",
    "backendPort": 443,
    "frontendPort": 10001,
    "createdAt": "2026-04-09T12:05:00.000Z"
  }
]
```

---

### Add server

```
POST /servers
```

**Request body**

| Field        | Type     | Required | Description                          |
|--------------|----------|----------|--------------------------------------|
| `ip`         | `string` | yes      | Backend server IP address            |
| `backendPort`| `number` | yes      | Backend port (1–65535, e.g. `443`)   |

`name` and `frontendPort` are generated automatically and returned in the response.

**Example request**

```bash
curl -X POST http://localhost:3000/servers \
  -H "Content-Type: application/json" \
  -H "x-api-key: your-secret-api-key" \
  -d '{
    "ip": "178.253.42.47",
    "backendPort": 443
  }'
```

**Response** `201 Created`

```json
{
  "id": 1,
  "name": "node_a3f1b2c9",
  "ip": "178.253.42.47",
  "backendPort": 443,
  "frontendPort": 10000,
  "createdAt": "2026-04-09T12:00:00.000Z"
}
```

**Errors**

| Code  | Reason                                          |
|-------|-------------------------------------------------|
| `400` | Validation failed (invalid IP, missing fields)  |
| `400` | HAProxy config invalid — changes rolled back     |
| `400` | No available frontend ports in configured range  |
| `401` | Invalid or missing API key                       |

---

### Remove server

```
DELETE /servers/:id
```

**Path parameters**

| Parameter | Type     | Description       |
|-----------|----------|-------------------|
| `id`      | `number` | Server ID         |

**Example request**

```bash
curl -X DELETE http://localhost:3000/servers/1 \
  -H "x-api-key: your-secret-api-key"
```

**Response** `200 OK`

**Errors**

| Code  | Reason                                          |
|-------|-------------------------------------------------|
| `400` | Server with this ID not found                    |
| `400` | HAProxy config invalid — changes rolled back     |
| `401` | Invalid or missing API key                       |

---

## How it works

1. API receives a request (add/remove server)
2. Database is updated (SQLite via Prisma)
3. HAProxy config file is regenerated from all servers in the database
4. Config is validated (`haproxy -c`)
5. HAProxy is reloaded (`systemctl reload haproxy`)
6. If reload fails — config and database are rolled back to the previous state, `400` is returned

## HAProxy config structure

Each server creates a frontend + backend pair:

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

## Environment variables

| Variable             | Default                    | Description                        |
|----------------------|----------------------------|------------------------------------|
| `DATABASE_URL`       | `file:./dev.db`            | SQLite database path               |
| `API_KEY`            | —                          | API key for authentication         |
| `HAPROXY_CONFIG_PATH`| `/etc/haproxy/haproxy.cfg` | Path to HAProxy config file        |
| `PORT`               | `3000`                     | API server port                    |
| `FRONTEND_PORT_MIN`  | `10000`                    | Start of frontend port range       |
| `FRONTEND_PORT_MAX`  | `65000`                    | End of frontend port range         |

## Installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnomGrom/node/main/install.sh)
```

## Service management

```bash
systemctl status haproxy-node    # check status
systemctl restart haproxy-node   # restart API
journalctl -u haproxy-node -f    # live logs
```
