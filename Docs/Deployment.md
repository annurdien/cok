# Cok Deployment Guide

## Overview

Cok is a TCP-based tunneling system that exposes local services to the internet. It consists of two binaries:

- **`cok-server`** — The central server that manages tunnel connections and routes HTTP traffic
- **`cok`** — The local CLI client that establishes a tunnel to the server

## Quick Start

### Docker Compose (Recommended)

```bash
API_KEY_SECRET=your-secret-min-32-chars BASE_DOMAIN=tunnel.yourdomain.com \
  docker compose up -d

# Verify it's running
curl http://localhost:8080/health
```

### Docker

```bash
docker run -d \
  -p 8080:8080 \
  -p 5000:5000 \
  -e API_KEY_SECRET=your-secret-min-32-chars \
  -e BASE_DOMAIN=tunnel.yourdomain.com \
  ghcr.io/annurdien/cok-server:latest
```

### From Source

```bash
swift build -c release --product cok-server
API_KEY_SECRET=your-secret BASE_DOMAIN=localhost .build/release/cok-server
```

## Configuration

### Server Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | `8080` | HTTP port for incoming tunnel traffic |
| `TCP_PORT` | `5000` | TCP port for client tunnel connections |
| `BASE_DOMAIN` | `localhost` | Base domain for subdomain routing |
| `MAX_TUNNELS` | `1000` | Maximum concurrent tunnels |
| `API_KEY_SECRET` | *(required)* | Secret for HMAC-SHA256 API key validation |
| `ALLOWED_HOSTS` | `localhost` | Comma-separated allowed `Host` header values |
| `HEALTH_CHECK_PATHS` | `/health,/health/live,/health/ready` | Comma-separated health check paths |

### Client Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_SERVER_HOST` | *(required)* | Tunnel server hostname |
| `COK_SERVER_PORT` | `5000` | Tunnel server TCP port |
| `COK_SUBDOMAIN` | *(required)* | Requested subdomain |
| `COK_API_KEY` | *(required)* | API key for authentication |
| `COK_LOCAL_HOST` | `localhost` | Local hostname to forward to |
| `COK_LOCAL_PORT` | `3000` | Local port to forward to |

> **Note**: When using the `cok` CLI, `--server` accepts `host:port` (e.g. `tunnel.example.com:5000`) and overrides `COK_SERVER_HOST`/`COK_SERVER_PORT`.

## API Key Generation

API keys are stateless HMAC-SHA256 signatures that survive server restarts:

```bash
# Generate a key for a subdomain
swift Scripts/generate-api-key.swift <subdomain> <secret>

# Or use make
make generate-key
```

Keys are validated server-side without any stored state — the server recomputes `HMAC-SHA256(subdomain, secret)` and compares. You can also create ephemeral in-memory keys programmatically via `AuthService.createAPIKey(for:expiresIn:)`.

## Production Checklist

### Security

- [ ] Set a strong `API_KEY_SECRET` (min 32 characters)
- [ ] Enable TLS on reverse proxy (expose 443 only; never expose 5000 without TLS termination)
- [ ] Configure firewall: restrict direct access to 8080 and 5000; expose only 80/443 publicly
- [ ] Configure `ALLOWED_HOSTS` to your domain(s)
- [ ] Review rate limiting at the load balancer

### Networking

- [ ] Configure reverse proxy (nginx/Caddy) — HTTP traffic via HTTP proxy, TCP tunnel port via **stream proxy**
- [ ] Set up DNS wildcard: `*.tunnel.yourdomain.com → your-server-ip`
- [ ] Configure connection timeouts appropriately

### Monitoring

- [ ] Monitor health endpoints (`/health/live`, `/health/ready`)
- [ ] Set up log aggregation (server logs to stdout in structured format)

### Capacity

- [ ] Set `MAX_TUNNELS` based on available memory
- [ ] Configure Docker/Kubernetes resource limits

## Reverse Proxy Configuration

The TCP tunnel port (`5000`) carries the raw binary protocol — it **must** be proxied at the TCP/stream level, **not** the HTTP level.

### Nginx

```nginx
# /etc/nginx/nginx.conf — stream block (TCP proxy for tunnel clients)
stream {
    server {
        listen 5000;
        proxy_pass 127.0.0.1:5000;
        proxy_timeout 1h;
        proxy_connect_timeout 10s;
    }
}

# /etc/nginx/sites-enabled/cok — HTTP block (tunnel traffic)
server {
    listen 80;
    server_name *.tunnel.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Caddy

```caddyfile
# HTTP tunnel traffic
*.tunnel.yourdomain.com {
    reverse_proxy localhost:8080
}
```

For the TCP tunnel port, use nginx `stream {}` or a dedicated TCP proxy alongside Caddy.

## Health Checks

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Basic liveness (200 OK if process is up) |
| `GET /health/live` | Liveness probe |
| `GET /health/ready` | Readiness probe (checks active tunnel state) |

### Kubernetes Probes

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health/ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

Set `terminationGracePeriodSeconds: 45` to allow the 30-second graceful shutdown to complete.

## Graceful Shutdown

The server handles `SIGTERM` and `SIGINT`:

1. Stops accepting new connections
2. Waits for in-flight requests to complete (30 s timeout)
3. Disconnects all active tunnels
4. Exits cleanly

## Troubleshooting

```bash
# Check HTTP server health
curl -v http://localhost:8080/health

# Test TCP tunnel port connectivity
nc -zv localhost 5000

# Run benchmarks
swift build -c release --product Benchmarks
.build/release/Benchmarks
```

Server logs are written to stdout in structured format. Use your preferred log aggregator (Loki, CloudWatch, Datadog, etc.).
