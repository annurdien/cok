# Cok Architecture

## System Overview

Cok is a TCP-based tunnel system that allows developers to expose local services to the internet through secure tunnels.

```
┌─────────────┐    HTTP/S    ┌─────────────────┐    TCP tunnel    ┌──────────────────┐
│   Browser   │ ──────────▶  │    cok-server   │ ◀─────────────── │    cok (client)  │
│             │              │                 │                  │                  │
└─────────────┘              │  ┌───────────┐  │                  │  ┌─────────────┐ │
                             │  │HTTPServer │  │                  │  │TunnelClient │ │
                             │  └─────┬─────┘  │                  │  └──────┬──────┘ │
                             │        │        │                  │         │        │
                             │  ┌─────▼─────┐  │                  │  ┌──────▼──────┐ │
                             │  │  Router   │  │                  │  │TunnelTCPCl. │ │
                             │  └─────┬─────┘  │                  │  └──────┬──────┘ │
                             │        │        │                  │         │        │
                             │  ┌─────▼──────┐ │                  │  ┌──────▼──────┐ │
                             │  │Connection  │ │                  │  │LocalRequest │ │
                             │  │ Manager    │ │                  │  │  Handler    │ │
                             │  └─────┬──────┘ │                  │  └──────┬──────┘ │
                             │        │        │                  │         │        │
                             │  ┌─────▼─────┐  │                  │  ┌──────▼──────┐ │
                             │  │TCPServer  │  │                  │  │Local Service│ │
                             │  └───────────┘  │                  │  └─────────────┘ │
                             └─────────────────┘                  └──────────────────┘
```

## Module Structure

The project is a Swift Package with three targets:

| Target | Product | Role |
|--------|---------|------|
| `TunnelCore` | Library | Shared protocol, models, networking, security |
| `TunnelServer` | `cok-server` executable | Server-side: HTTP + TCP servers |
| `TunnelClient` | `cok` executable | Client CLI tool |

## Core Components

### TunnelCore (Shared Library)

Foundation layer shared by both server and client:

#### Protocol (`Sources/TunnelCore/Protocol/`)
- **`ProtocolFrame`** — Binary frame: Version + Type + Flags + PayloadLen + Payload + CRC32
- **`ProtocolVersion`** — Version struct; current = 1.0, encoded as `0x10`
- **`ProtocolFlags`** — OptionSet: `compressed`, `encrypted`, `requiresACK`
- **`MessageType`** — Enum of message type byte values
- **`MessageCodec`** — Protocol + `BinaryMessageCodec` impl for encode/decode
- **`ProtocolFrameHandlers`** — NIO channel handlers for frame encode/decode

#### Models (`Sources/TunnelCore/Models/`)
- **`Messages.swift`** — All message structs: `ConnectRequest`, `ConnectResponse`, `HTTPRequestMessage`, `HTTPResponseMessage`, `PingMessage`, `PongMessage`, `DisconnectMessage`, `ErrorMessage`
- **`Errors.swift`** — Domain error types (`TunnelError`, `ServerError`, etc.)

#### Networking (`Sources/TunnelCore/Networking/`)
- **`HTTPConversion`** — Utilities to convert between NIO HTTP types and internal message types

#### Observability (`Sources/TunnelCore/Observability/`)
- **`HealthChecker`** — Health status tracking for `/health`, `/health/live`, `/health/ready`

#### Security (`Sources/TunnelCore/Security/`)
- **`SubdomainValidator`** — Validates subdomain format (`^[a-z0-9-]+$`, max 63 chars)
- **`RateLimiter`** — Token bucket rate limiting (actor)
- **`InputSanitizer`** — Sanitizes user-supplied strings before logging/storage
- **`RequestSizeValidator`** — Enforces payload size limits

#### Lifecycle (`Sources/TunnelCore/Lifecycle/`)
- **`GracefulShutdown`** — Registers SIGTERM/SIGINT handlers; runs shutdown hooks with a configurable timeout (default 30 s)

---

### TunnelServer (`cok-server`)

#### Auth (`Sources/TunnelServer/Auth/`)
- **`AuthService`** (actor) — Two-path API key validation:
  1. **Stateless HMAC path**: verifies `HMAC-SHA256(subdomain, secret)` — deterministic, survives server restarts
  2. **Registered key path**: in-memory registry for programmatically created keys with optional expiry

#### Config (`Sources/TunnelServer/Config/`)
- **`ServerConfig`** — Loaded from environment variables at startup

#### Connection (`Sources/TunnelServer/Connection/`)
- **`ConnectionManager`** (actor) — Central tunnel registry:
  - Maps `subdomain → TunnelConnection`
  - Enforces `MAX_TUNNELS` limit
  - Sends `HTTPRequestMessage` frames to tunnel channels via `BinaryMessageCodec`
- **`TCPServer`** — Listens on `TCP_PORT`; NIO pipeline per connection handles: `ProtocolFrameHandlers` → auth → `ConnectionManager` registration

#### Forwarding (`Sources/TunnelServer/Forwarding/`)
- **`RequestTracker`** (actor) — Tracks in-flight requests; matches HTTP responses back to pending continuations with a configurable timeout (default 30 s)
- **`RequestConverter`** — Converts NIO HTTP types into `HTTPRequestMessage`

#### HTTP (`Sources/TunnelServer/HTTP/`)
- **`HTTPServer`** — Listens on `HTTP_PORT`; routes incoming HTTP by subdomain via `ConnectionManager`; handles `/health*` internally; applies rate limiting

---

### TunnelClient (`cok`)

#### CLI (`Sources/TunnelClient/CLI/`)
- **`CokCLI`** — `ArgumentParser` entry point. Flags: `--port/-p`, `--subdomain/-s`, `--api-key`, `--server`, `--host`, `--verbose/-v`. Auto-generates a random subdomain (`adj-noun-NNN`) if `--subdomain` is not provided.

#### Client (`Sources/TunnelClient/Client/`)
- **`TunnelClient`** (actor) — Orchestrates `TunnelTCPClient`, `CircuitBreaker`, and `LocalRequestHandler`
- **`TunnelTCPClient`** — NIO-based TCP connection to the server; handles `ConnectRequest`/`ConnectResponse` handshake, keep-alive Ping/Pong, and auto-reconnect with exponential backoff
- **`LocalRequestHandler`** — Decodes incoming `HTTPRequest` frames and forwards them to `localhost:<port>` via `AsyncHTTPClient`; sends `HTTPResponse` frames back
- **`CircuitBreaker`** (actor) — Protects the local service: opens after N consecutive failures (default: 5), probes with half-open state after timeout (default: 60 s)

#### Config (`Sources/TunnelClient/Config/`)
- **`ClientConfig`** — Configuration struct; loaded from environment or constructed via CLI flags

## Protocol

### Frame Format

```
┌──────────────┬──────────────┬───────┬────────────────┬────────────────┬──────────┐
│ Version (1B) │ MsgType (1B) │ Flags │ PayloadLen (4B)│ Payload (var)  │ CRC32(4B)│
└──────────────┴──────────────┴───────┴────────────────┴────────────────┴──────────┘
```

Payloads use a **custom binary encoding** (length-prefixed strings, fixed-width integers, raw bytes). See [Protocol.md](Protocol.md) for the full specification.

### Message Types

| Type | Code | Description |
|------|------|-------------|
| ConnectRequest | 0x01 | Client initiates tunnel connection |
| ConnectResponse | 0x02 | Server sends tunnel details + public URL |
| HTTPRequest | 0x10 | Server forwards HTTP request to client |
| HTTPResponse | 0x11 | Client returns HTTP response to server |
| Ping | 0x20 | Keep-alive ping |
| Pong | 0x21 | Keep-alive pong |
| Disconnect | 0x30 | Graceful disconnection with reason |
| Error | 0xFF | Error message with code + metadata |

## Data Flow

### Request Path

1. Browser sends HTTP request to `myapp.tunnel.example.com`
2. `HTTPServer` receives request; checks rate limit
3. Router extracts subdomain `myapp`
4. `ConnectionManager` finds the `TunnelConnection` for `myapp`
5. `RequestConverter` builds an `HTTPRequestMessage`; `RequestTracker` stores the pending continuation
6. `ConnectionManager.sendRequest()` encodes the message via `BinaryMessageCodec` → `ProtocolFrame` → writes to NIO channel
7. Client's `TunnelTCPClient` receives the frame; `LocalRequestHandler` decodes it
8. `LocalRequestHandler` forwards the request to `http://localhost:<port>` via `AsyncHTTPClient`
9. Response flows back as an `HTTPResponse` frame over the same TCP tunnel
10. Server's `RequestTracker` matches the `requestID` and fulfils the pending HTTP continuation

### Connection Establishment

1. Client connects to `TCP_PORT` on the server
2. Client sends `ConnectRequest` with `apiKey` + optional `requestedSubdomain`
3. Server's `AuthService` validates the key (stateless HMAC first, then registered key fallback)
4. Server's `SubdomainValidator` checks the subdomain format; `ConnectionManager` checks for conflicts
5. Server registers the tunnel in `ConnectionManager` and sends `ConnectResponse` with `publicURL`
6. Tunnel is ready for traffic; keep-alive Ping/Pong begins

## Concurrency Model

Uses **Swift 6 strict concurrency** with actors throughout:

| Actor | Responsibility |
|-------|---------------|
| `ConnectionManager` | Tunnel registry; subdomain → channel mapping |
| `AuthService` | In-memory key store + HMAC validation |
| `RequestTracker` | Pending request continuations + timeout |
| `RateLimiter` | Token bucket rate limit state |
| `TunnelClient` | Client lifecycle coordination |
| `TunnelTCPClient` | TCP connection state + message routing |
| `CircuitBreaker` | Failure tracking + state machine |
| `HealthChecker` | Health status aggregation |

All public types are `Sendable`-compliant for safe concurrent access across actor boundaries.

## Health Checks

| Endpoint | Description |
|----------|-------------|
| `/health` | Basic health (always 200 if process is up) |
| `/health/live` | Liveness probe |
| `/health/ready` | Readiness probe (checks active tunnel state) |

Additional paths can be configured via `HEALTH_CHECK_PATHS`.
