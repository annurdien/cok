# Cok Architecture

## System Overview

Cok is a tunnel server that allows developers to expose local services to the internet through secure TCP-based tunnels.

```
┌─────────────┐    HTTPS     ┌─────────────────┐    TCP tunnel    ┌─────────────┐
│   Browser   │ ───────────> │    cok-server   │ <───────────────│ cok-client  │
│             │              │                 │                 │             │
└─────────────┘              │  ┌───────────┐  │                 │ ┌─────────┐ │
                             │  │HTTP Server│  │                 │ │  Proxy  │ │
                             │  └─────┬─────┘  │                 │ └────┬────┘ │
                             │        │        │                 │      │      │
                             │  ┌─────▼─────┐  │                 │ ┌────▼────┐ │
                             │  │ Router    │  │                 │ │ Local   │ │
                             │  └─────┬─────┘  │                 │ │ Service │ │
                             │        │        │                 │ └─────────┘ │
                             │  ┌─────▼─────┐  │                 └─────────────┘
                             │  │Connection │  │
                             │  │ Manager   │  │
                             │  └─────┬─────┘  │
                             │        │        │
                             │  ┌─────▼─────┐  │
                             │  │ TCP tunnel │  │
                             │  │  Server   │  │
                             │  └───────────┘  │
                             └─────────────────┘
```

## Core Components

### TunnelCore (Shared Library)

The foundation layer providing:

- **Protocol**: Binary framing protocol with versioning
- **Messages**: HTTP request/response message types
- **Security**: Subdomain validation, API key handling
- **Networking**: Buffer pooling, connection management
- **Observability**: Logging, metrics, tracing

### TunnelServer

Production server with:

- **HTTPServer**: Handles incoming HTTP traffic
- **TCP tunnelServer**: Manages tunnel connections
- **ConnectionManager**: Routes requests to tunnels
- **AuthService**: Validates API keys
- **RateLimiter**: Token bucket rate limiting

### TunnelClient

CLI tool providing:

- **TCP tunnel connection** to server
- **Local HTTP proxy** forwarding
- **Auto-reconnection** logic
- **Subdomain management**

## Protocol

### Frame Format

```
┌──────────────┬──────────────┬───────┬────────────────┬─────────────────┐
│ Version (1B) │ MsgType (1B) │ Flags │ PayloadLen (4B)│ Payload (var)   │
└──────────────┴──────────────┴───────┴────────────────┴─────────────────┘
```

### Message Types

| Type | Code | Description |
|------|------|-------------|
| Connect | 0x01 | Initial tunnel connection |
| ConnectAck | 0x02 | Server acknowledgment |
| HTTPRequest | 0x10 | HTTP request to tunnel |
| HTTPResponse | 0x11 | HTTP response from tunnel |
| Ping | 0xF0 | Keep-alive ping |
| Pong | 0xF1 | Keep-alive pong |
| Error | 0xFF | Error message |

## Data Flow

### Request Path

1. Browser sends HTTP request to `myapp.tunnel.example.com`
2. HTTP Server receives request
3. Router extracts subdomain `myapp`
4. ConnectionManager finds tunnel for subdomain
5. Request encoded as ProtocolFrame
6. Frame sent over TCP tunnel to client
7. Client decodes frame
8. Local proxy forwards to `localhost:3000`
9. Response flows back through same path

### Connection Establishment

1. Client connects to TCP tunnel endpoint
2. Client sends Connect message with subdomain + API key
3. Server validates credentials
4. Server registers tunnel in ConnectionManager
5. Server sends ConnectAck with assigned URL
6. Tunnel is ready for traffic

## Performance Optimizations

### Buffer Pooling

Reusable `ByteBuffer` pool to minimize allocations in the NIO pipeline:

```swift
let pool = BufferPool(maxPoolSize: 100, defaultCapacity: 8192)
let buffer = pool.acquire(minimumCapacity: 1024)
defer { pool.release(buffer) }
```

An actor-based variant (`BufferPoolActor`) is also available for use outside NIO pipelines.

### Backpressure Control

Flow control to prevent memory exhaustion under load:

```swift
let controller = BackpressureController(configuration: .default)
let result = await controller.requestPermission()
guard result.allowed else { /* shed load */ }
```

## Observability

### Metrics

Prometheus-format metrics exposed at `/metrics`:

- `cok_requests_total` — Total requests by method and status
- `cok_request_duration_seconds` — Request latency histogram
- `cok_active_connections` — Current active tunnel count
- `cok_rate_limit_hits` — Rate limit rejections

### Tracing

W3C Trace Context propagation:

```swift
let span = await tracer.startSpan("http.request")
await span.setTag("http.method", "GET")
// ... work
await tracer.endSpan(span.id)
```

### Health Checks

- `/health` - Basic health
- `/health/live` - Liveness (process is running)
- `/health/ready` - Readiness (accepting traffic)

## Concurrency Model

Uses Swift 6 strict concurrency with actors:

- `ConnectionManager` - Actor managing tunnel registry
- `MetricsCollector` - Actor for thread-safe metrics
- `RateLimiter` - Actor for rate limit state
- `RequestTracker` - Actor for pending requests

All components are `Sendable` compliant for safe concurrent access.
