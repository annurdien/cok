import Foundation
import NIOCore

public protocol MessageCodec: Sendable {
    func encode<T: Encodable & Sendable>(_ message: T) throws -> ByteBuffer

    func decode<T: Decodable & Sendable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T
}

public struct JSONMessageCodec: MessageCodec {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func encode<T: Encodable & Sendable>(_ message: T) throws -> ByteBuffer {
        let data = try encoder.encode(message)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T
    {
        guard let data = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes)
        else {
            throw CodecError.invalidData
        }
        return try decoder.decode(type, from: Data(data))
    }
}

/// Codec errors
public enum CodecError: Error, Sendable, CustomStringConvertible {
    case invalidData
    case encodingFailed(any Error)
    case decodingFailed(any Error)

    public var description: String {
        switch self {
        case .invalidData:
            return "Invalid data"
        case .encodingFailed(let error):
            return "Encoding failed: \(error)"
        case .decodingFailed(let error):
            return "Decoding failed: \(error)"
        }
    }
}
