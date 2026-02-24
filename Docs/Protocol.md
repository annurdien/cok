# Cok Protocol Specification

Version: 1.0

## Overview

Cok uses a custom binary protocol for communication between client and server over TCP. The protocol provides:
- Version negotiation
- Type-safe message passing
- Error detection (CRC32)
- Efficient custom binary encoding
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
7       N       Payload       Custom binary-encoded message payload
7+N     4       CRC32         Frame checksum (little endian)
```

**Total frame size**: 11 + N bytes (where N = payload length)

**Maximum payload size**: 10 MB

## Protocol Version

Current version: **1.0**

Encoded as: `0x10` (high nibble = major `1`, low nibble = minor `0`)

### Version Compatibility

- **Major version** must match for compatibility
- **Minor version** differences are allowed (backwards compatible)

## Message Types

| Type | Value | Direction | Description |
|------|-------|-----------|-------------|
| ConnectRequest | 0x01 | Client → Server | Client initiates tunnel connection |
| ConnectResponse | 0x02 | Server → Client | Server assigns tunnel details |
| HTTPRequest | 0x10 | Server → Client | Server forwards HTTP request to client |
| HTTPResponse | 0x11 | Client → Server | Client sends HTTP response to server |
| Ping | 0x20 | Either | Keep-alive ping |
| Pong | 0x21 | Either | Keep-alive pong response |
| Disconnect | 0x30 | Either | Graceful disconnection |
| Error | 0xFF | Either | Error message |

## Flags

Flags are stored as an 8-bit bitmask:

| Bit | Flag | Description |
|-----|------|-------------|
| 0 | Compressed | Payload is compressed (future use) |
| 1 | Encrypted | Payload is encrypted (future use) |
| 2 | RequiresACK | Message requires acknowledgment |

## Message Payloads

All payloads use a **custom binary encoding** (not JSON). Fields are serialized inline using length-prefixed strings, fixed-width integers, and binary sequences. See `Sources/TunnelCore/Protocol/MessageCodec.swift` and `Sources/TunnelCore/Models/Messages.swift` for the full implementation.

### ConnectRequest (Client → Server)

| Field | Type | Notes |
|-------|------|-------|
| `apiKey` | length-prefixed string | HMAC-SHA256 hex key |
| `requestedSubdomain` | optional string | `nil` for auto-generation |
| `clientVersion` | length-prefixed string | e.g. `"0.1.0"` |
| `capabilities` | string array | e.g. `["http/1.1"]` |

### ConnectResponse (Server → Client)

| Field | Type | Notes |
|-------|------|-------|
| `tunnelID` | UUID (16 bytes) | Assigned tunnel UUID |
| `subdomain` | length-prefixed string | Final assigned subdomain |
| `publicURL` | length-prefixed string | e.g. `http://myapp.tunnel.example.com` |
| `expiresAt` | Date (8-byte timestamp) | Session expiry |

### HTTPRequest (Server → Client)

| Field | Type | Notes |
|-------|------|-------|
| `requestID` | UUID (16 bytes) | Correlates response |
| `method` | length-prefixed string | e.g. `"GET"` |
| `path` | length-prefixed string | e.g. `"/api/users"` |
| `headers` | array of (name, value) pairs | Length-prefixed strings |
| `body` | length-prefixed bytes | Raw body bytes |
| `remoteAddress` | length-prefixed string | Client IP |

### HTTPResponse (Client → Server)

| Field | Type | Notes |
|-------|------|-------|
| `requestID` | UUID (16 bytes) | Matches request |
| `statusCode` | UInt16 | e.g. `200` |
| `headers` | array of (name, value) pairs | Length-prefixed strings |
| `body` | length-prefixed bytes | Raw body bytes |

### Ping

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | Date (8-byte timestamp) | Send time |

### Pong

| Field | Type | Notes |
|-------|------|-------|
| `pingTimestamp` | Date (8-byte timestamp) | Original ping time |
| `pongTimestamp` | Date (8-byte timestamp) | Reply time |

### Disconnect

| Field | Type | Notes |
|-------|------|-------|
| `reason` | length-prefixed string | See reasons below |
| `message` | optional string | Human-readable detail |

**Disconnect Reasons**:
- `client_shutdown`
- `server_shutdown`
- `timeout`
- `protocol_error`
- `authentication_failed`
- `rate_limit_exceeded`
- `unknown`

### Error

| Field | Type | Notes |
|-------|------|-------|
| `code` | UInt16 | Error code |
| `message` | length-prefixed string | Human-readable description |
| `metadata` | map of string→string | Key-value pairs (count prefix + pairs) |

## CRC32 Calculation

CRC32 is calculated over the entire frame **excluding** the CRC field itself using the ZLib `crc32` function:
- Library: `ZLib` (swift-collective/zlib)
- Algorithm: standard CRC32 (ZLib default polynomial)
- Endianness: little endian

## Implementation Notes

### Encoding

- **Integers**: little endian
- **Strings**: length-prefixed UTF-8 (4-byte UInt32 length + bytes)
- **Optional strings**: 1-byte presence flag + length-prefixed string
- **Dates**: 8-byte UInt64 milliseconds since Unix epoch
- **UUIDs**: 16 raw bytes

### Error Handling

- Invalid CRC → discard frame, close connection
- Unknown message type → send Error message
- Invalid payload → send Error message
- Version mismatch (major) → send Error, gracefully disconnect

### Maximum Sizes

- **Payload**: 10 MB (hardcoded in `ProtocolFrame.maxPayloadSize`)
- **Subdomain**: 63 characters (validated in `SubdomainValidator`)

## Security

1. **Authentication**: `apiKey` required in `ConnectRequest`; validated via HMAC-SHA256 against the server secret
2. **Rate limiting**: enforced at the server HTTP layer before requests reach tunnels
3. **Input validation**: all string fields sanitized via `InputSanitizer`
4. **Size limits**: payload cap prevents DoS via oversized frames

## Future Extensions

- Compression support (flag bit 0 — infrastructure present, not yet implemented)
- End-to-end encryption (flag bit 1 — reserved)
- Multiplexing (multiple tunnels per TCP connection)
