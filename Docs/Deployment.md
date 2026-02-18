# Cok Deployment Guide

## Overview

Cok is a high-performance TCP-based tunneling system that exposes local services to the internet through secure tunnels.

## Components

- **cok-server**: The central tunnel server that manages connections and routes traffic
- **cok** (client): Local CLI tool that establishes tunnels to the server

## Quick Start

### Docker Compose (Recommended)

```bash
# Set required variables and start
API_KEY_SECRET=your-secret-min-32-chars BASE_DOMAIN=tunnel.yourdomain.com \
  docker compose up -d

# Verify it's running
curl http://localhost:8080/health
```

### Docker

```bash
# Pull and run the server image
docker run -d \
  -p 8080:8080 \
  -p 5000:5000 \
  -e API_KEY_SECRET=your-secret-min-32-chars \
  -e BASE_DOMAIN=tunnel.yourdomain.com \
  ghcr.io/annurdien/cok-server:latest
```

### From Source

```bash
# Build release binary
swift build -c release --product cok-server

# Run server
API_KEY_SECRET=your-secret BASE_DOMAIN=localhost .build/release/cok-server
```

## Configuration

### Server Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | `8080` | HTTP server port for tunnel traffic |
| `TCP_PORT` | `5000` | TCP port for client tunnel connections |
| `BASE_DOMAIN` | `localhost` | Base domain for subdomains |
| `MAX_TUNNELS` | `1000` | Maximum concurrent tunnels |
| `API_KEY_SECRET` | *(required)* | Secret for API key HMAC validation |
| `METRICS_PATH` | `/metrics` | Prometheus metrics endpoint |

### Client Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_SERVER_URL` | `localhost:5000` | TCP server address (`host:port`) |
| `COK_SUBDOMAIN` | *(auto)* | Requested subdomain |
| `COK_API_KEY` | *(required)* | API key for authentication |

## Production Checklist

### Security

- [ ] Set strong `API_KEY_SECRET` (min 32 characters)
- [ ] Enable TLS on reverse proxy
- [ ] Configure firewall rules (expose only 80/443 and TCP port publicly)
- [ ] Set up rate limiting at load balancer
- [ ] Review and restrict CORS if needed

### Networking

- [ ] Configure reverse proxy (nginx/Caddy) — HTTP traffic via HTTP proxy, TCP tunnel port via stream proxy
- [ ] Set up DNS wildcard for subdomains (`*.tunnel.yourdomain.com`)
- [ ] Configure connection timeouts appropriately

### Monitoring

- [ ] Set up Prometheus scraping for `/metrics`
- [ ] Configure health check endpoint monitoring (`/health/live`, `/health/ready`)
- [ ] Set up log aggregation
- [ ] Configure alerting thresholds

### Scaling

- [ ] Configure resource limits in Docker/Kubernetes
- [ ] Set `MAX_TUNNELS` based on available memory
- [ ] Plan for horizontal scaling if needed

## Reverse Proxy Configuration

The TCP tunnel port (`5000`) uses raw TCP — it must be proxied at the **stream** level, not HTTP level.

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

For the TCP tunnel port, use Caddy's `tcp` layer via a separate config or use nginx stream for port 5000.

## Health Checks

### Endpoints

- `GET /health` - Basic health check (HTTP 200 OK)
- `GET /health/live` - Liveness probe
- `GET /health/ready` - Readiness probe
- `GET /metrics` - Prometheus metrics

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

## Graceful Shutdown

The server handles SIGTERM and SIGINT signals gracefully:

1. Stops accepting new connections
2. Waits for existing requests to complete (30s timeout)
3. Closes all tunnel connections
4. Exits cleanly

For Kubernetes, set `terminationGracePeriodSeconds: 45` to allow time for shutdown.

## Troubleshooting

### Connection Issues

```bash
# Check if server is accepting HTTP traffic
curl -v http://localhost:8080/health

# Test TCP tunnel port connectivity
nc -zv localhost 5000
```

### Performance Issues

```bash
# Check Prometheus metrics
curl http://localhost:8080/metrics

# Run benchmarks
swift build -c release --product Benchmarks
.build/release/Benchmarks
```

### Logs

Server logs are output to stdout with structured JSON format. Use your preferred log aggregator (e.g. Loki, CloudWatch, Datadog).
