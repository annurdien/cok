import Logging
import NIOCore

public func makeLogger(label: String) -> Logger {
    var logger = Logger(label: label)
    logger.logLevel = .info
    return logger
}

public typealias LogMetadata = Logger.Metadata
public typealias LogMetadataValue = Logger.MetadataValue
