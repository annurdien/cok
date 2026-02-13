import Foundation
import NIOCore

public struct ConnectRequest: Codable, Sendable, CustomStringConvertible {
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

    public var description: String {
        "ConnectRequest(subdomain: \(requestedSubdomain ?? "auto"), version: \(clientVersion))"
    }
}

// MARK: - Connect Response

/// Server responds with tunnel assignment
public struct ConnectResponse: Codable, Sendable, CustomStringConvertible {
    /// Unique tunnel identifier
    public let tunnelID: UUID

    /// Assigned subdomain
    public let subdomain: String

    /// Session token (JWT) for subsequent auth
    public let sessionToken: String

    /// Public URL for accessing the tunnel
    public let publicURL: String

    /// Session expiration time
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

    public var description: String {
        "ConnectResponse(tunnel: \(tunnelID), subdomain: \(subdomain), url: \(publicURL))"
    }
}

// MARK: - HTTP Header

/// HTTP header key-value pair (Codable compatible)
public struct HTTPHeader: Codable, Sendable, CustomStringConvertible {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var description: String {
        "\(name): \(value)"
    }
}

// MARK: - HTTP Request Message

/// Server forwards HTTP request to client
public struct HTTPRequestMessage: Codable, Sendable, CustomStringConvertible {
    /// Unique request identifier for correlation
    public let requestID: UUID

    /// HTTP method (GET, POST, etc.)
    public let method: String

    /// Request path
    public let path: String

    /// HTTP headers
    public let headers: [HTTPHeader]

    /// Request body (base64 encoded for JSON)
    public let body: Data

    /// Remote address of original requester
    public let remoteAddress: String

    public init(
        requestID: UUID,
        method: String,
        path: String,
        headers: [HTTPHeader],
        body: Data,
        remoteAddress: String
    ) {
        self.requestID = requestID
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public var description: String {
        "HTTPRequest(\(requestID), \(method) \(path), \(body.count) bytes)"
    }
}

// MARK: - HTTP Response Message

/// Client sends HTTP response back to server
public struct HTTPResponseMessage: Codable, Sendable, CustomStringConvertible {
    /// Request ID this response corresponds to
    public let requestID: UUID

    /// HTTP status code
    public let statusCode: UInt16

    /// Response headers
    public let headers: [HTTPHeader]

    /// Response body (base64 encoded for JSON)
    public let body: Data

    public init(
        requestID: UUID,
        statusCode: UInt16,
        headers: [HTTPHeader],
        body: Data
    ) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var description: String {
        "HTTPResponse(\(requestID), status: \(statusCode), \(body.count) bytes)"
    }
}

// MARK: - Ping/Pong Messages

/// Keep-alive ping message
public struct PingMessage: Codable, Sendable {
    /// Timestamp when ping was sent
    public let timestamp: Date

    public init(timestamp: Date = Date()) {
        self.timestamp = timestamp
    }
}

/// Keep-alive pong response
public struct PongMessage: Codable, Sendable {
    /// Original ping timestamp
    public let pingTimestamp: Date

    /// Pong response timestamp
    public let pongTimestamp: Date

    public init(pingTimestamp: Date, pongTimestamp: Date = Date()) {
        self.pingTimestamp = pingTimestamp
        self.pongTimestamp = pongTimestamp
    }
}

// MARK: - Disconnect Message

/// Graceful disconnection message
public struct DisconnectMessage: Codable, Sendable, CustomStringConvertible {
    /// Reason for disconnection
    public enum Reason: String, Codable, Sendable {
        case clientShutdown = "client_shutdown"
        case serverShutdown = "server_shutdown"
        case timeout = "timeout"
        case protocolError = "protocol_error"
        case authenticationFailed = "authentication_failed"
        case rateLimitExceeded = "rate_limit_exceeded"
    }

    public let reason: Reason
    public let message: String?

    public init(reason: Reason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }

    public var description: String {
        let msg = message.map { " - \($0)" } ?? ""
        return "Disconnect(\(reason.rawValue)\(msg))"
    }
}

// MARK: - Error Message

/// Error message sent by either party
public struct ErrorMessage: Codable, Sendable, CustomStringConvertible {
    /// Error code (matches HTTP-style codes)
    public let code: UInt16

    /// Human-readable error message
    public let message: String

    /// Additional context/metadata
    public let metadata: [String: String]?

    public init(code: UInt16, message: String, metadata: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.metadata = metadata
    }

    public var description: String {
        "Error(\(code): \(message))"
    }
}
