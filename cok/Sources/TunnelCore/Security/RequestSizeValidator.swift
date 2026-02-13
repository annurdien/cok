import Foundation
import NIOCore

/// Validates request sizes to prevent memory exhaustion attacks
public struct RequestSizeValidator: Sendable {
    
    // MARK: - Constants
    
    /// Maximum size for HTTP headers (16 KB)
    public static let maxHeadersSize = 16 * 1024
    
    /// Maximum size for single request body (10 MB)
    public static let maxBodySize = 10 * 1024 * 1024
    
    /// Maximum size for WebSocket frame (1 MB)
    public static let maxWebSocketFrameSize = 1 * 1024 * 1024
    
    /// Maximum number of headers per request
    public static let maxHeaderCount = 100
    
    /// Maximum length for a single header value (8 KB)
    public static let maxHeaderValueLength = 8 * 1024
    
    /// Maximum length for URL path (2 KB)
    public static let maxPathLength = 2 * 1024
    
    /// Maximum length for subdomain (63 chars per RFC 1123)
    public static let maxSubdomainLength = 63
    
    // MARK: - Validation Errors
    
    public enum ValidationError: Error, Sendable {
        case headersTooLarge(size: Int, maximum: Int)
        case bodyTooLarge(size: Int, maximum: Int)
        case frameTooLarge(size: Int, maximum: Int)
        case tooManyHeaders(count: Int, maximum: Int)
        case headerValueTooLong(length: Int, maximum: Int)
        case pathTooLong(length: Int, maximum: Int)
        case subdomainTooLong(length: Int, maximum: Int)
        
        public var message: String {
            switch self {
            case .headersTooLarge(let size, let max):
                return "Headers too large: \(size) bytes (max: \(max) bytes)"
            case .bodyTooLarge(let size, let max):
                return "Request body too large: \(size) bytes (max: \(max) bytes)"
            case .frameTooLarge(let size, let max):
                return "WebSocket frame too large: \(size) bytes (max: \(max) bytes)"
            case .tooManyHeaders(let count, let max):
                return "Too many headers: \(count) (max: \(max))"
            case .headerValueTooLong(let length, let max):
                return "Header value too long: \(length) chars (max: \(max))"
            case .pathTooLong(let length, let max):
                return "URL path too long: \(length) chars (max: \(max))"
            case .subdomainTooLong(let length, let max):
                return "Subdomain too long: \(length) chars (max: \(max))"
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Validates headers size
    /// - Parameter size: Total size of all headers
    /// - Throws: ValidationError if headers are too large
    public static func validateHeadersSize(_ size: Int) throws {
        guard size <= maxHeadersSize else {
            throw ValidationError.headersTooLarge(size: size, maximum: maxHeadersSize)
        }
    }
    
    /// Validates request body size
    /// - Parameter size: Size of the request body
    /// - Throws: ValidationError if body is too large
    public static func validateBodySize(_ size: Int) throws {
        guard size <= maxBodySize else {
            throw ValidationError.bodyTooLarge(size: size, maximum: maxBodySize)
        }
    }
    
    /// Validates WebSocket frame size
    /// - Parameter size: Size of the WebSocket frame
    /// - Throws: ValidationError if frame is too large
    public static func validateFrameSize(_ size: Int) throws {
        guard size <= maxWebSocketFrameSize else {
            throw ValidationError.frameTooLarge(size: size, maximum: maxWebSocketFrameSize)
        }
    }
    
    /// Validates ByteBuffer size
    /// - Parameter buffer: The ByteBuffer to validate
    /// - Throws: ValidationError if buffer is too large
    public static func validateBufferSize(_ buffer: ByteBuffer) throws {
        try validateBodySize(buffer.readableBytes)
    }
    
    /// Validates header count
    /// - Parameter count: Number of headers
    /// - Throws: ValidationError if there are too many headers
    public static func validateHeaderCount(_ count: Int) throws {
        guard count <= maxHeaderCount else {
            throw ValidationError.tooManyHeaders(count: count, maximum: maxHeaderCount)
        }
    }
    
    /// Validates a single header value length
    /// - Parameter value: The header value to validate
    /// - Throws: ValidationError if value is too long
    public static func validateHeaderValue(_ value: String) throws {
        guard value.count <= maxHeaderValueLength else {
            throw ValidationError.headerValueTooLong(length: value.count, maximum: maxHeaderValueLength)
        }
    }
    
    /// Validates URL path length
    /// - Parameter path: The URL path to validate
    /// - Throws: ValidationError if path is too long
    public static func validatePath(_ path: String) throws {
        guard path.count <= maxPathLength else {
            throw ValidationError.pathTooLong(length: path.count, maximum: maxPathLength)
        }
    }
    
    /// Validates subdomain length
    /// - Parameter subdomain: The subdomain to validate
    /// - Throws: ValidationError if subdomain is too long
    public static func validateSubdomain(_ subdomain: String) throws {
        guard subdomain.count <= maxSubdomainLength else {
            throw ValidationError.subdomainTooLong(length: subdomain.count, maximum: maxSubdomainLength)
        }
    }
    
    /// Validates all aspects of an HTTP request message
    /// - Parameter message: The HTTP request message
    /// - Throws: ValidationError if any validation fails
    public static func validateHTTPRequest(_ message: HTTPRequestMessage) throws {
        // Validate path length
        try validatePath(message.path)
        
        // Validate header count
        try validateHeaderCount(message.headers.count)
        
        // Validate each header value
        for header in message.headers {
            try validateHeaderValue(header.value)
        }
        
        // Validate body size
        try validateBodySize(message.body.count)
    }
    
    /// Validates all aspects of an HTTP response message
    /// - Parameter message: The HTTP response message
    /// - Throws: ValidationError if any validation fails
    public static func validateHTTPResponse(_ message: HTTPResponseMessage) throws {
        // Validate header count
        try validateHeaderCount(message.headers.count)
        
        // Validate each header value
        for header in message.headers {
            try validateHeaderValue(header.value)
        }
        
        // Validate body size
        try validateBodySize(message.body.count)
    }
    
    /// Formats byte size in human-readable format
    /// - Parameter bytes: Number of bytes
    /// - Returns: Human-readable string (e.g., "1.5 MB")
    public static func formatSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        } else {
            return String(format: "%.2f %@", value, units[unitIndex])
        }
    }
}
