# Cok - HTTP Tunnel

Expose local web servers to the internet via public URLs.

## Usage

### Simple usage
```bash
cok -p 8080

#With custom subdomain
cok -p 8080 -s myapp
```

### With configs
```bash
cok --port 8080
cok --port 8080 --subdomain myapp
cok --port 8080 --subdomain myapp --api-key YOUR_KEY
```

### Options

| Option | Short | Environment | Description |
|--------|-------|-------------|-------------|
| `--port` | `-p` | | Local port to forward (required) |
| `--subdomain` | `-s` | `COK_SUBDOMAIN` | Subdomain (auto-generated if not set) |
| `--api-key` | | `COK_API_KEY` | API key for authentication |
| `--server` | | `COK_SERVER_URL` | Server URL (default: `ws://localhost:8081`) |
| `--host` | | | Local host (default: `127.0.0.1`) |
| `--verbose` | `-v` | | Verbose output |

## Deploy Your Own Server

### Docker (Recommended)

```bash
docker compose up -d server
```

Or with custom configuration:

```bash
docker run -d -p 8080:8080 -p 8081:8081 \
  -e COK_API_KEY_SECRET=your-secret-key-min-32-chars \
  -e COK_DOMAIN=tunnel.yourdomain.com \
  cok-server
```

### From Source

```bash
swift build -c release
.build/release/cok-server
```

### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_HTTP_PORT` | 8080 | HTTP server port for tunnel traffic |
| `COK_WS_PORT` | 8081 | WebSocket port for client connections |
| `COK_DOMAIN` | localhost | Base domain for subdomains |
| `COK_MAX_TUNNELS` | 1000 | Maximum concurrent tunnels |
| `COK_API_KEY_SECRET` | (required) | Secret for API key HMAC validation |

## Reverse Proxy Setup

### Nginx

```nginx
# Tunnel HTTP traffic
server {
    listen 80;
    server_name *.tunnel.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}

# WebSocket for client connections
server {
    listen 443 ssl;
    server_name tunnel.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location /ws {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
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

### DNS

Set up wildcard DNS:
```
*.tunnel.yourdomain.com → your-server-ip
```

## Health & Monitoring

### Health Endpoints

```bash
# Basic health check
curl http://localhost:8080/health

# Liveness probe (for k8s)
curl http://localhost:8080/health/live

# Readiness probe (for k8s)
curl http://localhost:8080/health/ready
```

### Prometheus Metrics

Metrics available at `/metrics`:

```bash
curl http://localhost:8080/metrics
```

Key metrics: `cok_active_tunnels`, `cok_requests_total`, `cok_request_duration_seconds`

### Kubernetes

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

terminationGracePeriodSeconds: 45
```

## Security

- **Authentication**: API key with HMAC-SHA256 validation
- **Rate Limiting**: Token bucket per client IP
- **Subdomain Validation**: Reserved words blocked, length limits enforced
- **Input Sanitization**: Request size limits, header validation
- **Graceful Shutdown**: Handles SIGTERM/SIGINT, drains connections

## Production Checklist

- [ ] Set strong `COK_API_KEY_SECRET` (min 32 characters)
- [ ] Enable TLS via reverse proxy
- [ ] Configure wildcard DNS
- [ ] Set up Prometheus monitoring
- [ ] Configure log aggregation
- [ ] Set resource limits in container

## Documentation

- [Architecture](Docs/Architecture.md) - System design and components
- [Protocol](Docs/Protocol.md) - Binary protocol specification
- [Deployment](Docs/Deployment.md) - Detailed deployment guide

## License

MIT
