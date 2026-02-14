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
| `--server` | | `COK_SERVER_URL` | Server URL (default: `ws://localhost:8081`) |
| `--host` | | | Local host (default: `127.0.0.1`) |
| `--verbose` | `-v` | | Verbose output |

## Deploy Your Own Server

### Docker
```bash
docker run -d -p 8080:8080 -p 8081:8081 \
  -e COK_API_KEY_SECRET=your-secret-key-min-32-chars \
  -e COK_DOMAIN=tunnel.yourdomain.com \
  cok-server
```

### From Source
```bash
swift build -c release --product cok-server
.build/release/cok-server
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COK_HTTP_PORT` | 8080 | HTTP server port for tunnel traffic |
| `COK_WS_PORT` | 8081 | WebSocket port for client connections |
| `COK_DOMAIN` | localhost | Base domain for subdomains |
| `COK_MAX_TUNNELS` | 1000 | Maximum concurrent tunnels |
| `COK_API_KEY_SECRET` | (required) | Secret for API key HMAC validation |

### Reverse Proxy Setup

For production, use a reverse proxy like Nginx or Caddy:

```nginx
# HTTP traffic
server {
    listen 80;
    server_name *.tunnel.yourdomain.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}

# WebSocket for clients  
server {
    listen 443 ssl;
    server_name tunnel.yourdomain.com;
    location /ws {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Set up wildcard DNS: `*.tunnel.yourdomain.com → your-server-ip`

## License

MIT
