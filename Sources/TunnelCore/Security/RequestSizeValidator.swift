import Foundation
import NIOCore

public struct RequestSizeValidator: Sendable {

    public static let maxHeadersSize = 16 * 1024
    public static let maxBodySize = 10 * 1024 * 1024
    public static let maxWebSocketFrameSize = 1 * 1024 * 1024
    public static let maxHeaderCount = 100
    public static let maxHeaderValueLength = 8 * 1024
    public static let maxPathLength = 2 * 1024
    public static let maxSubdomainLength = 63

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
            case .headersTooLarge(let s, let m): return "Headers too large: \(s) bytes (max: \(m))"
            case .bodyTooLarge(let s, let m): return "Body too large: \(s) bytes (max: \(m))"
            case .frameTooLarge(let s, let m): return "Frame too large: \(s) bytes (max: \(m))"
            case .tooManyHeaders(let c, let m): return "Too many headers: \(c) (max: \(m))"
            case .headerValueTooLong(let l, let m): return "Header value too long: \(l) (max: \(m))"
            case .pathTooLong(let l, let m): return "Path too long: \(l) (max: \(m))"
            case .subdomainTooLong(let l, let m): return "Subdomain too long: \(l) (max: \(m))"
            }
        }
    }

    public static func validateHeadersSize(_ size: Int) throws {
        guard size <= maxHeadersSize else {
            throw ValidationError.headersTooLarge(size: size, maximum: maxHeadersSize)
        }
    }

    public static func validateBodySize(_ size: Int) throws {
        guard size <= maxBodySize else {
            throw ValidationError.bodyTooLarge(size: size, maximum: maxBodySize)
        }
    }

    public static func validateFrameSize(_ size: Int) throws {
        guard size <= maxWebSocketFrameSize else {
            throw ValidationError.frameTooLarge(size: size, maximum: maxWebSocketFrameSize)
        }
    }

    public static func validateBufferSize(_ buffer: ByteBuffer) throws {
        try validateBodySize(buffer.readableBytes)
    }

    public static func validateHeaderCount(_ count: Int) throws {
        guard count <= maxHeaderCount else {
            throw ValidationError.tooManyHeaders(count: count, maximum: maxHeaderCount)
        }
    }

    public static func validateHeaderValue(_ value: String) throws {
        guard value.count <= maxHeaderValueLength else {
            throw ValidationError.headerValueTooLong(
                length: value.count, maximum: maxHeaderValueLength)
        }
    }

    public static func validatePath(_ path: String) throws {
        guard path.count <= maxPathLength else {
            throw ValidationError.pathTooLong(length: path.count, maximum: maxPathLength)
        }
    }

    public static func validateSubdomain(_ subdomain: String) throws {
        guard subdomain.count <= maxSubdomainLength else {
            throw ValidationError.subdomainTooLong(
                length: subdomain.count, maximum: maxSubdomainLength)
        }
    }

    public static func validateHTTPRequest(_ message: HTTPRequestMessage) throws {
        try validatePath(message.path)
        try validateHeaderCount(message.headers.count)
        for header in message.headers { try validateHeaderValue(header.value) }
        try validateBodySize(message.body.readableBytes)
    }

    public static func validateHTTPResponse(_ message: HTTPResponseMessage) throws {
        try validateHeaderCount(message.headers.count)
        for header in message.headers { try validateHeaderValue(header.value) }
        try validateBodySize(message.body.readableBytes)
    }

    public static func formatSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return idx == 0
            ? "\(Int(value)) \(units[idx])" : String(format: "%.2f %@", value, units[idx])
    }
}
