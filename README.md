# Cok - HTTP Tunnel

Expose local web servers to the internet via public URLs.

1. [Install](#install)
2. [Usage](#usage)
3. [Deploy Your Own Server](#deploy-your-own-server)
4. [Configuration](#configuration)
5. [License](#license)

## Install

### Brew (macOS) - Recommended
```bash
brew tap annurdien/tap
brew install cok
```

### Download Binary
Download the latest release for your platform: [cok/releases](https://github.com/annurdien/cok/releases)

### Docker
```bash
docker pull ghcr.io/annurdien/cok-server:latest
```

### From Source
```bash
git clone https://github.com/annurdien/cok.git
cd cok
swift build -c release --product cok
```

## Usage

### Quick Start
```bash
cok -p 8080
```

The above command opens a tunnel and forwards traffic to `localhost:8080`.

### Development & Testing

For local development and testing:

```bash
# Quick start - build and setup everything
make all

# In terminal 1: Start test HTTP server
make test-site

# In terminal 2: Start tunnel client
make test-client

# Visit: http://test-client.localhost:8080
```

See `make help` for all available commands.

### With Custom Subdomain
```bash
cok -p 8080 -s myapp
```

### Options

| Flag | Short | Environment | Description |
|------|-------|-------------|-------------|
| `--port` | `-p` | | Local port to forward (required) |
| `--subdomain` | `-s` | `COK_SUBDOMAIN` | Custom subdomain (auto-generated if not set) |
| `--api-key` | | `COK_API_KEY` | API key for authentication |
| `--server` | | `COK_SERVER_URL` | Server address (default: `localhost:5000`) |
| `--host` | | | Local host (default: `127.0.0.1`) |
| `--verbose` | `-v` | | Verbose output |

## Deploy Your Own Server

### Docker (Recommended)
```bash
docker run -d \
  -p 8080:8080 \
  -p 5000:5000 \
  -e API_KEY_SECRET=your-secret-key-min-32-chars \
  -e BASE_DOMAIN=tunnel.yourdomain.com \
  ghcr.io/annurdien/cok-server:latest
```

### Docker Compose
```bash
API_KEY_SECRET=your-secret-key BASE_DOMAIN=tunnel.yourdomain.com \
  docker compose up -d
```

### From Source
```bash
swift build -c release --product cok-server
API_KEY_SECRET=your-secret BASE_DOMAIN=localhost .build/release/cok-server
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | `8080` | HTTP server port for tunnel traffic |
| `TCP_PORT` | `5000` | TCP port for client tunnel connections |
| `BASE_DOMAIN` | `localhost` | Base domain for subdomains |
| `MAX_TUNNELS` | `1000` | Maximum concurrent tunnels |
| `API_KEY_SECRET` | *(required)* | Secret for API key HMAC validation |
| `METRICS_PATH` | `/metrics` | Prometheus metrics endpoint path |

### Reverse Proxy Setup

For production, use a reverse proxy like Nginx or Caddy. The TCP tunnel port (`5000`) requires **stream proxying** (not HTTP), so it must be handled at the TCP level:

```nginx
# nginx.conf (stream block — for TCP tunnel port)
stream {
    server {
        listen 5000;
        proxy_pass 127.0.0.1:5000;
    }
}

# HTTP block — for tunnel traffic
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
```

Set up wildcard DNS: `*.tunnel.yourdomain.com → your-server-ip`

## License

MIT
