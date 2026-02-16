import Foundation
import NIOCore

// MARK: - Connect Request

public struct ConnectRequest: BinarySerializable, Sendable, CustomStringConvertible {
    public let apiKey: String
    public let requestedSubdomain: String?
    public let clientVersion: String
    public let capabilities: [String]

    public init(
        apiKey: String,
        requestedSubdomain: String? = nil,
        clientVersion: String,
        capabilities: [String] = ["http/1.1"]
    ) {
        self.apiKey = apiKey
        self.requestedSubdomain = requestedSubdomain
        self.clientVersion = clientVersion
        self.capabilities = capabilities
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeStringWithLength(apiKey)
        buffer.writeOptionalString(requestedSubdomain)
        buffer.writeStringWithLength(clientVersion)
        buffer.writeArray(capabilities) { buf, cap in
            buf.writeStringWithLength(cap)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let apiKey = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("apiKey")
        }
        self.apiKey = apiKey
        self.requestedSubdomain = buffer.readOptionalString()
        guard let clientVersion = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("clientVersion")
        }
        self.clientVersion = clientVersion
        guard
            let capabilities = buffer.readArray(readElement: { buf in buf.readStringWithLength() })
        else {
            throw BinaryError.decodingError("capabilities")
        }
        self.capabilities = capabilities
    }

    public var description: String {
        "ConnectRequest(subdomain: \(requestedSubdomain ?? "auto"), version: \(clientVersion))"
    }
}

// MARK: - Connect Response

public struct ConnectResponse: BinarySerializable, Sendable, CustomStringConvertible {
    public let tunnelID: UUID
    public let subdomain: String
    public let sessionToken: String
    public let publicURL: String
    public let expiresAt: Date

    public init(
        tunnelID: UUID,
        subdomain: String,
        sessionToken: String,
        publicURL: String,
        expiresAt: Date
    ) {
        self.tunnelID = tunnelID
        self.subdomain = subdomain
        self.sessionToken = sessionToken
        self.publicURL = publicURL
        self.expiresAt = expiresAt
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeUUID(tunnelID)
        buffer.writeStringWithLength(subdomain)
        buffer.writeStringWithLength(sessionToken)
        buffer.writeStringWithLength(publicURL)
        buffer.writeDate(expiresAt)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let tunnelID = buffer.readUUID() else { throw BinaryError.decodingError("tunnelID") }
        self.tunnelID = tunnelID
        guard let subdomain = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("subdomain")
        }
        self.subdomain = subdomain
        guard let sessionToken = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("sessionToken")
        }
        self.sessionToken = sessionToken
        guard let publicURL = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("publicURL")
        }
        self.publicURL = publicURL
        guard let expiresAt = buffer.readDate() else {
            throw BinaryError.decodingError("expiresAt")
        }
        self.expiresAt = expiresAt
    }

    public var description: String {
        "ConnectResponse(tunnel: \(tunnelID), subdomain: \(subdomain), url: \(publicURL))"
    }
}

// MARK: - HTTP Header

public struct HTTPHeader: BinarySerializable, Sendable, CustomStringConvertible {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeStringWithLength(name)
        buffer.writeStringWithLength(value)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let name = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("header name")
        }
        self.name = name
        guard let value = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("header value")
        }
        self.value = value
    }

    public var description: String {
        "\(name): \(value)"
    }
}

// MARK: - HTTP Request Message

public struct HTTPRequestMessage: BinarySerializable, Sendable, CustomStringConvertible {
    public let requestID: UUID
    public let method: String
    public let path: String
    public let headers: [HTTPHeader]
    public let body: ByteBuffer
    public let remoteAddress: String

    public init(
        requestID: UUID,
        method: String,
        path: String,
        headers: [HTTPHeader],
        body: ByteBuffer,
        remoteAddress: String
    ) {
        self.requestID = requestID
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeUUID(requestID)
        buffer.writeStringWithLength(method)
        buffer.writeStringWithLength(path)
        buffer.writeArray(headers) { buf, header in header.serialize(into: &buf) }
        buffer.writeBufferWithLength(body)
        buffer.writeStringWithLength(remoteAddress)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let requestID = buffer.readUUID() else {
            throw BinaryError.decodingError("requestID")
        }
        self.requestID = requestID
        guard let method = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("method")
        }
        self.method = method
        guard let path = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("path")
        }
        self.path = path
        guard let headers = buffer.readArray(readElement: { try? HTTPHeader(from: &$0) }) else {
            throw BinaryError.decodingError("headers")
        }
        self.headers = headers
        guard let body = buffer.readBufferWithLength() else {
            throw BinaryError.decodingError("body")
        }
        self.body = body
        guard let remoteAddress = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("remoteAddress")
        }
        self.remoteAddress = remoteAddress
    }

    public var description: String {
        "HTTPRequest(\(requestID), \(method) \(path), \(body.readableBytes) bytes)"
    }
}

// MARK: - HTTP Response Message

public struct HTTPResponseMessage: BinarySerializable, Sendable, CustomStringConvertible {
    public let requestID: UUID
    public let statusCode: UInt16
    public let headers: [HTTPHeader]
    public let body: ByteBuffer

    public init(
        requestID: UUID,
        statusCode: UInt16,
        headers: [HTTPHeader],
        body: ByteBuffer
    ) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeUUID(requestID)
        buffer.writeInteger(statusCode)
        buffer.writeArray(headers) { buf, header in header.serialize(into: &buf) }
        buffer.writeBufferWithLength(body)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let requestID = buffer.readUUID() else {
            throw BinaryError.decodingError("requestID")
        }
        self.requestID = requestID
        guard let statusCode = buffer.readInteger(as: UInt16.self) else {
            throw BinaryError.decodingError("statusCode")
        }
        self.statusCode = statusCode
        guard let headers = buffer.readArray(readElement: { try? HTTPHeader(from: &$0) }) else {
            throw BinaryError.decodingError("headers")
        }
        self.headers = headers
        guard let body = buffer.readBufferWithLength() else {
            throw BinaryError.decodingError("body")
        }
        self.body = body
    }

    public var description: String {
        "HTTPResponse(\(requestID), status: \(statusCode), \(body.readableBytes) bytes)"
    }
}

// MARK: - Ping/Pong Messages

public struct PingMessage: BinarySerializable, Sendable {
    public let timestamp: Date

    public init(timestamp: Date = Date()) {
        self.timestamp = timestamp
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeDate(timestamp)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let timestamp = buffer.readDate() else {
            throw BinaryError.decodingError("timestamp")
        }
        self.timestamp = timestamp
    }
}

public struct PongMessage: BinarySerializable, Sendable {
    public let pingTimestamp: Date
    public let pongTimestamp: Date

    public init(pingTimestamp: Date, pongTimestamp: Date = Date()) {
        self.pingTimestamp = pingTimestamp
        self.pongTimestamp = pongTimestamp
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeDate(pingTimestamp)
        buffer.writeDate(pongTimestamp)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let pingTimestamp = buffer.readDate() else {
            throw BinaryError.decodingError("pingTimestamp")
        }
        self.pingTimestamp = pingTimestamp
        guard let pongTimestamp = buffer.readDate() else {
            throw BinaryError.decodingError("pongTimestamp")
        }
        self.pongTimestamp = pongTimestamp
    }
}

// MARK: - Disconnect Message

public struct DisconnectMessage: BinarySerializable, Sendable, CustomStringConvertible {
    public enum Reason: String, Sendable {
        case clientShutdown = "client_shutdown"
        case serverShutdown = "server_shutdown"
        case timeout = "timeout"
        case protocolError = "protocol_error"
        case authenticationFailed = "authentication_failed"
        case rateLimitExceeded = "rate_limit_exceeded"
        case unknown = "unknown"
    }

    public let reason: Reason
    public let message: String?

    public init(reason: Reason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeStringWithLength(reason.rawValue)
        buffer.writeOptionalString(message)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let reasonString = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("reason")
        }
        self.reason = Reason(rawValue: reasonString) ?? .unknown
        self.message = buffer.readOptionalString()
    }

    public var description: String {
        let msg = message.map { " - \($0)" } ?? ""
        return "Disconnect(\(reason.rawValue)\(msg))"
    }
}

// MARK: - Error Message

public struct ErrorMessage: BinarySerializable, Sendable, CustomStringConvertible {
    public let code: UInt16
    public let message: String
    public let metadata: [String: String]?

    public init(code: UInt16, message: String, metadata: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.metadata = metadata
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeInteger(code)
        buffer.writeStringWithLength(message)
        // Metadata as array of key-value pairs?
        // Or specific serialization for map?
        if let metadata = metadata {
            buffer.writeInteger(UInt32(metadata.count))
            for (key, value) in metadata {
                buffer.writeStringWithLength(key)
                buffer.writeStringWithLength(value)
            }
        } else {
            buffer.writeInteger(UInt32(0))
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let code = buffer.readInteger(as: UInt16.self) else {
            throw BinaryError.decodingError("code")
        }
        self.code = code
        guard let message = buffer.readStringWithLength() else {
            throw BinaryError.decodingError("message")
        }
        self.message = message

        guard let count = buffer.readInteger(as: UInt32.self) else {
            throw BinaryError.decodingError("metadata count")
        }

        if count > 0 {
            var metadata: [String: String] = [:]
            for _ in 0..<count {
                guard let key = buffer.readStringWithLength(),
                    let value = buffer.readStringWithLength()
                else {
                    throw BinaryError.decodingError("metadata item")
                }
                metadata[key] = value
            }
            self.metadata = metadata
        } else {
            self.metadata = nil
        }
    }

    public var description: String {
        "Error(\(code): \(message))"
    }
}

public enum BinaryError: Error {
    case decodingError(String)
}
