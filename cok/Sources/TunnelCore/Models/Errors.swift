import Foundation

public enum TunnelError: Error, Sendable, CustomStringConvertible {
    case client(ClientError, context: ErrorContext)
    case server(ServerError, context: ErrorContext)
    case network(NetworkError, context: ErrorContext)

    public var description: String {
        switch self {
        case .client(let error, let context):
            return "Client error: \(error) [\(context)]"
        case .server(let error, let context):
            return "Server error: \(error) [\(context)]"
        case .network(let error, let context):
            return "Network error: \(error) [\(context)]"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .client(let error, _): return error.isRecoverable
        case .server(let error, _): return error.isRecoverable
        case .network(let error, _): return error.isRecoverable
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .client(let error, _): return error.retryAfter
        case .server(let error, _): return error.retryAfter
        case .network(let error, _): return error.retryAfter
        }
    }
}

public enum ClientError: Error, Sendable, CustomStringConvertible {
    case invalidSubdomain(String)
    case authenticationFailed
    case rateLimitExceeded(retryAfter: TimeInterval)
    case invalidRequest(String)
    case localServerUnreachable(host: String, port: Int)
    case connectionFailed(String)
    case timeout

    public var description: String {
        switch self {
        case .invalidSubdomain(let subdomain):
            return "Invalid subdomain: \(subdomain)"
        case .authenticationFailed:
            return "Authentication failed"
        case .rateLimitExceeded(let retryAfter):
            return "Rate limit exceeded (retry after \(retryAfter)s)"
        case .invalidRequest(let reason):
            return "Invalid request: \(reason)"
        case .localServerUnreachable(let host, let port):
            return "Local server unreachable: \(host):\(port)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .timeout:
            return "Request timeout"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .rateLimitExceeded, .localServerUnreachable, .connectionFailed, .timeout:
            return true
        case .invalidSubdomain, .authenticationFailed, .invalidRequest:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .rateLimitExceeded(let delay): return delay
        case .localServerUnreachable, .connectionFailed: return 1.0
        case .timeout: return 0.5
        default: return nil
        }
    }
}

public enum ServerError: Error, Sendable, CustomStringConvertible {
    case internalError(String)
    case serviceUnavailable
    case subdomainTaken
    case tunnelNotFound(UUID)
    case requestTimeout
    case gatewayTimeout

    public var description: String {
        switch self {
        case .internalError(let reason):
            return "Internal error: \(reason)"
        case .serviceUnavailable:
            return "Service unavailable"
        case .subdomainTaken:
            return "Subdomain already taken"
        case .tunnelNotFound(let id):
            return "Tunnel not found: \(id)"
        case .requestTimeout:
            return "Request timeout"
        case .gatewayTimeout:
            return "Gateway timeout"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .serviceUnavailable, .requestTimeout, .gatewayTimeout:
            return true
        case .internalError, .subdomainTaken, .tunnelNotFound:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .serviceUnavailable: return 5.0
        case .requestTimeout, .gatewayTimeout: return 1.0
        default: return nil
        }
    }
}

public enum NetworkError: Error, Sendable, CustomStringConvertible {
    case connectionLost
    case connectionRefused
    case dnsFailure(host: String)
    case tlsHandshakeFailed
    case writeError(String)
    case readError(String)
    case channelClosed

    public var description: String {
        switch self {
        case .connectionLost:
            return "Connection lost"
        case .connectionRefused:
            return "Connection refused"
        case .dnsFailure(let host):
            return "DNS failure for host: \(host)"
        case .tlsHandshakeFailed:
            return "TLS handshake failed"
        case .writeError(let reason):
            return "Write error: \(reason)"
        case .readError(let reason):
            return "Read error: \(reason)"
        case .channelClosed:
            return "Channel closed"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .connectionLost, .connectionRefused, .channelClosed:
            return true
        case .dnsFailure, .tlsHandshakeFailed, .writeError, .readError:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .connectionLost, .connectionRefused: return 2.0
        case .channelClosed: return 0.1
        default: return nil
        }
    }
}

public struct ErrorContext: Sendable, CustomStringConvertible {
    public let timestamp: Date
    public let component: String
    public let requestID: UUID?
    public let metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        component: String,
        requestID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.component = component
        self.requestID = requestID
        self.metadata = metadata
    }

    public var description: String {
        var parts = [
            ISO8601DateFormatter().string(from: timestamp),
            component,
        ]

        if let rid = requestID {
            parts.append("requestID=\(rid.uuidString.prefix(8))")
        }

        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(value)")
        }

        return parts.joined(separator: " ")
    }
}
