# Cok Protocol Specification

Version: 1.0

## Overview

Cok uses a custom binary protocol for communication between client and server over WebSocket. The protocol provides:
- Version negotiation
- Type-safe message passing
- Error detection (CRC32)
- Efficient binary encoding
- Future extensibility (flags)

## Frame Format

All messages are encoded in frames with the following structure:

```
Offset  Size    Field         Description
------  ----    -----         -----------
0       1       Version       Protocol version (high nibble: major, low nibble: minor)
1       1       Type          Message type identifier
2       1       Flags         Protocol flags (compression, encryption, etc.)
3       4       PayloadLen    Payload length in bytes (little endian)
7       N       Payload       JSON-encoded message payload
7+N     4       CRC32         Frame checksum (little endian)
```

**Total frame size**: 11 + N bytes (where N = payload length)

## Protocol Version

Current version: **1.0**

Encoded as: `0x10` (major=1, minor=0)

### Version Compatibility

- **Major version** must match for compatibility
- **Minor version** differences are allowed (backwards compatible)

## Message Types

| Type | Value | Description |
|------|-------|-------------|
| ConnectRequest | 0x01 | Client initiates tunnel connection |
| ConnectResponse | 0x02 | Server assigns tunnel details |
| HTTPRequest | 0x10 | Server forwards HTTP request to client |
| HTTPResponse | 0x11 | Client sends HTTP response to server |
| Ping | 0x20 | Keep-alive ping |
| Pong | 0x21 | Keep-alive pong response |
| Disconnect | 0x30 | Graceful disconnection |
| Error | 0xFF | Error message |

## Flags

Flags are stored as an 8-bit bitmask:

| Bit | Flag | Description |
|-----|------|-------------|
| 0 | Compressed | Payload is compressed (future use) |
| 1 | Encrypted | Payload is encrypted (future use) |
| 2 | RequiresACK | Message requires acknowledgment |

## Message Payloads

All payloads are JSON-encoded.

### ConnectRequest (Client → Server)

```json
{
  "apiKey": "cok_prod_...",
  "requestedSubdomain": "myapp",  // optional
  "clientVersion": "1.0.0",
  "capabilities": ["http/1.1"]
}
```

### ConnectResponse (Server → Client)

```json
{
  "tunnelID": "uuid",
  "subdomain": "myapp",
  "sessionToken": "jwt...",
  "publicURL": "http://myapp.cok.dev",
  "expiresAt": "2026-02-14T00:00:00Z"
}
```

### HTTPRequest (Server → Client)

```json
{
  "requestID": "uuid",
  "method": "GET",
  "path": "/api/users",
  "headers": [
    {"name": "Host", "value": "myapp.cok.dev"},
    {"name": "User-Agent", "value": "curl/7.0"}
  ],
  "body": "base64...",
  "remoteAddress": "1.2.3.4"
}
```

### HTTPResponse (Client → Server)

```json
{
  "requestID": "uuid",
  "statusCode": 200,
  "headers": [
    {"name": "Content-Type", "value": "application/json"}
  ],
  "body": "base64..."
}
```

### Ping/Pong

```json
// Ping
{
  "timestamp": "2026-02-13T23:00:00Z"
}

// Pong
{
  "pingTimestamp": "2026-02-13T23:00:00Z",
  "pongTimestamp": "2026-02-13T23:00:00.001Z"
}
```

### Disconnect

```json
{
  "reason": "client_shutdown",  // enum
  "message": "User terminated connection"  // optional
}
```

**Disconnect Reasons**:
- `client_shutdown`
- `server_shutdown`
- `timeout`
- `protocol_error`
- `authentication_failed`
- `rate_limit_exceeded`

### Error

```json
{
  "code": 400,
  "message": "Invalid subdomain format",
  "metadata": {
    "field": "subdomain",
    "pattern": "^[a-z0-9-]+$"
  }
}
```

## CRC32 Calculation

CRC32 is calculated over the entire frame **excluding** the CRC field itself:
- Polynomial: `0xEDB88320`
- Initial value: `0xFFFFFFFF`
- Final XOR: `0xFFFFFFFF`

## Implementation Notes

### Maximum Sizes

- **Payload**: 10 MB (configurable)
- **Subdomain**: 63 characters
- **Headers**: 8 KB total

### Encoding

- **Integers**: Little endian
- **Strings**: UTF-8
- **Binary data**: Base64 (in JSON payloads)
- **Dates**: ISO 8601 format

### Error Handling

- Invalid CRC → Discard frame, close connection
- Unknown message type → Send Error message
- Invalid JSON → Send Error message
- Version mismatch → Send Error, gracefully disconnect

## Security Considerations

1. **Authentication**: API key required in ConnectRequest
2. **Session tokens**: JWT for subsequent messages
3. **Rate limiting**: Enforced at server level
4. **Input validation**: All fields validated before processing
5. **Size limits**: Prevent DoS via large payloads

## Future Extensions

- Compression support (gzip, br)
- End-to-end encryption
- Binary payloads (avoid base64 overhead)
- Multiplexing (multiple tunnels per connection)
