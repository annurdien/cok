import Foundation
import NIOCore

public protocol MessageCodec: Sendable {
    func encode<T: BinarySerializable & Sendable>(_ message: T) throws -> ByteBuffer
    func encode<T: BinarySerializable & Sendable>(_ message: T, into buffer: inout ByteBuffer)
        throws
    func decode<T: BinarySerializable & Sendable>(_ type: T.Type, from buffer: ByteBuffer) throws
        -> T
}

public protocol BinarySerializable {
    func serialize(into buffer: inout ByteBuffer)
    init(from buffer: inout ByteBuffer) throws
}

public struct BinaryMessageCodec: MessageCodec {
    public init() {}

    public func encode<T: BinarySerializable & Sendable>(_ message: T) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        message.serialize(into: &buffer)
        return buffer
    }

    public func encode<T: BinarySerializable & Sendable>(
        _ message: T, into buffer: inout ByteBuffer
    ) throws {
        message.serialize(into: &buffer)
    }

    public func decode<T: BinarySerializable & Sendable>(
        _ type: T.Type, from buffer: ByteBuffer
    ) throws -> T {
        var buffer = buffer
        return try T(from: &buffer)
    }
}
