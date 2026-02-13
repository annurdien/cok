import Logging
import NIOCore
import Foundation

public func makeLogger(label: String) -> Logger {
    var logger = Logger(label: label)
    logger.logLevel = .info
    return logger
}

public typealias LogMetadata = Logger.Metadata
public typealias LogMetadataValue = Logger.MetadataValue

public struct LogContext: Sendable {
    public let requestID: UUID?
    public let tunnelID: UUID?
    public let subdomain: String?
    public let clientIP: String?

    public init(requestID: UUID? = nil, tunnelID: UUID? = nil, subdomain: String? = nil, clientIP: String? = nil) {
        self.requestID = requestID
        self.tunnelID = tunnelID
        self.subdomain = subdomain
        self.clientIP = clientIP
    }

    public var metadata: LogMetadata {
        var meta: LogMetadata = [:]
        if let requestID { meta["requestID"] = "\(requestID.uuidString.prefix(8))" }
        if let tunnelID { meta["tunnelID"] = "\(tunnelID.uuidString.prefix(8))" }
        if let subdomain { meta["subdomain"] = "\(subdomain)" }
        if let clientIP { meta["clientIP"] = "\(clientIP)" }
        return meta
    }
}

public struct StructuredLogger: Sendable {
    private let logger: Logger
    private let context: LogContext

    public init(label: String, context: LogContext = LogContext()) {
        var logger = Logger(label: label)
        logger.logLevel = .info
        self.logger = logger
        self.context = context
    }

    public init(logger: Logger, context: LogContext) {
        self.logger = logger
        self.context = context
    }

    public func with(requestID: UUID? = nil, tunnelID: UUID? = nil, subdomain: String? = nil, clientIP: String? = nil) -> StructuredLogger {
        let newContext = LogContext(
            requestID: requestID ?? context.requestID,
            tunnelID: tunnelID ?? context.tunnelID,
            subdomain: subdomain ?? context.subdomain,
            clientIP: clientIP ?? context.clientIP
        )
        return StructuredLogger(logger: logger, context: newContext)
    }

    public func trace(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.trace(message, metadata: merged(metadata))
    }

    public func debug(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.debug(message, metadata: merged(metadata))
    }

    public func info(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.info(message, metadata: merged(metadata))
    }

    public func notice(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.notice(message, metadata: merged(metadata))
    }

    public func warning(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.warning(message, metadata: merged(metadata))
    }

    public func error(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.error(message, metadata: merged(metadata))
    }

    public func critical(_ message: Logger.Message, metadata: LogMetadata? = nil) {
        logger.critical(message, metadata: merged(metadata))
    }

    private func merged(_ additional: LogMetadata?) -> LogMetadata {
        var meta = context.metadata
        if let additional {
            for (key, value) in additional { meta[key] = value }
        }
        return meta
    }
}
