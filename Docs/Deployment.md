# Cok Deployment Guide

## Overview

Cok is a high-performance WebSocket-based tunneling system that exposes local services to the internet through secure tunnels.

## Components

- **cok-server**: The central tunnel server that manages connections and routes traffic
- **cok-client**: Local client that establishes tunnels to the server

## Quick Start

### Docker Compose (Recommended)

```bash
# Start the server
docker compose up -d server

# Verify it's running
curl http://localhost:8080/health
```

### Docker Build

```bash
# Build server image
docker build --target server -t cok-server .

# Build client image
docker build --target client -t cok-client .

# Run server
docker run -d -p 8080:8080 -p 8081:8081 \
  -e COK_API_KEY_SECRET=your-secret-key \
  -e COK_DOMAIN=yourdomain.com \
  cok-server
```

### From Source

```bash
# Build release binaries
swift build -c release

# Run server
.build/release/cok-server

# Run client (in another terminal)
.build/release/cok-client connect --subdomain myapp --local-port 3000
```

## Configuration

### Server Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_HTTP_PORT` | 8080 | HTTP server port for tunnel traffic |
| `COK_WS_PORT` | 8081 | WebSocket port for tunnel connections |
| `COK_DOMAIN` | localhost | Base domain for subdomains |
| `COK_MAX_TUNNELS` | 1000 | Maximum concurrent tunnels |
| `COK_API_KEY_SECRET` | (required) | Secret for API key validation |

### Client Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_SERVER_URL` | ws://localhost:8081 | WebSocket server URL |
| `COK_LOCAL_PORT` | 3000 | Local port to forward traffic to |
| `COK_SUBDOMAIN` | (auto) | Requested subdomain |
| `COK_API_KEY` | (required) | API key for authentication |

## Production Checklist

### Security

- [ ] Set strong `COK_API_KEY_SECRET` (min 32 characters)
- [ ] Enable TLS on reverse proxy
- [ ] Configure firewall rules
- [ ] Set up rate limiting at load balancer
- [ ] Review and restrict CORS if needed

### Networking

- [ ] Configure reverse proxy (nginx/Caddy) with WebSocket support
- [ ] Set up DNS wildcard for subdomains (`*.tunnel.yourdomain.com`)
- [ ] Configure connection timeouts appropriately

### Monitoring

- [ ] Set up Prometheus scraping for `/metrics`
- [ ] Configure health check endpoint monitoring
- [ ] Set up log aggregation
- [ ] Configure alerting thresholds

### Scaling

- [ ] Configure resource limits in Docker/Kubernetes
- [ ] Set `COK_MAX_TUNNELS` based on available memory
- [ ] Plan for horizontal scaling if needed

## Reverse Proxy Configuration

### Nginx

```nginx
upstream cok_http {
    server 127.0.0.1:8080;
}

upstream cok_ws {
    server 127.0.0.1:8081;
}

# HTTP traffic
server {
    listen 80;
    server_name *.tunnel.yourdomain.com;

    location / {
        proxy_pass http://cok_http;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# WebSocket traffic
server {
    listen 443 ssl;
    server_name tunnel.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location /ws {
        proxy_pass http://cok_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### Caddy

```caddyfile
*.tunnel.yourdomain.com {
    reverse_proxy localhost:8080
}

tunnel.yourdomain.com {
    reverse_proxy /ws/* localhost:8081
}
```

## Health Checks

### Endpoints

- `GET /health` - Basic health check (HTTP 200 OK)
- `GET /health/live` - Liveness probe
- `GET /health/ready` - Readiness probe

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
# Check if server is accepting connections
curl -v http://localhost:8080/health

# Test WebSocket connectivity
wscat -c ws://localhost:8081
```

### Performance Issues

```bash
# Run benchmarks
swift build -c release --product Benchmarks
.build/release/Benchmarks
```

### Logs

Server logs are output to stdout with structured format. Use your preferred log aggregator.
