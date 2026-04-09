# HAProxy Node

API for managing HAProxy servers. Add and remove backend servers via REST API — HAProxy config is automatically regenerated, validated and reloaded.

## Installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnomGrom/node/main/install.sh)
```

The script will prompt for:
- **API key** — key for authenticating requests
- **API port** — port for the API server (default: 3000)
- **Frontend port range** — range for auto-generated frontend ports (default: 10000–65000)

Installs Node.js 22, HAProxy, clones the repo, builds the project, sets up a systemd service.

## Service management

```bash
systemctl status haproxy-node
systemctl restart haproxy-node
journalctl -u haproxy-node -f
```

## API

Full documentation: [docs/API.md](docs/API.md)

All requests require the `x-api-key` header.

### Add server

```bash
curl -X POST http://localhost:3000/servers \
  -H "Content-Type: application/json" \
  -H "x-api-key: your-key" \
  -d '{ "ip": "178.253.42.47", "backendPort": 443 }'
```

### List servers

```bash
curl http://localhost:3000/servers \
  -H "x-api-key: your-key"
```

### Remove server

```bash
curl -X DELETE http://localhost:3000/servers/1 \
  -H "x-api-key: your-key"
```
