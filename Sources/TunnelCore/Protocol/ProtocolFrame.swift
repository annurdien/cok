import Foundation
import NIOCore

/*
Wire format (Little Endian):
┌─────────────────────────────────────────────────────────┐
│ Version │ Type │ Flags │ PayloadLen │  Payload  │  CRC  │
│  1 byte │1 byte│1 byte │   4 bytes  │  N bytes  │4 bytes│
└─────────────────────────────────────────────────────────┘
*/
public struct ProtocolFrame: Sendable, CustomStringConvertible {
    public let version: ProtocolVersion
    public let messageType: MessageType
    public let flags: ProtocolFlags
    public let payload: ByteBuffer

    public static let headerSize = 11
    public static let maxPayloadSize: UInt32 = 10 * 1024 * 1024

    public init(
        version: ProtocolVersion = .current,
        messageType: MessageType,
        flags: ProtocolFlags = [],
        payload: ByteBuffer
    ) throws {
        guard payload.readableBytes <= Self.maxPayloadSize else {
            throw ProtocolError.payloadTooLarge(
                size: payload.readableBytes, max: Int(Self.maxPayloadSize))
        }

        self.version = version
        self.messageType = messageType
        self.flags = flags
        self.payload = payload
    }

    public func encode(into buffer: inout ByteBuffer) {
        // Version (1 byte)
        buffer.writeInteger(version.byte)

        // Message type (1 byte)
        buffer.writeInteger(messageType.rawValue)

        // Flags (1 byte)
        buffer.writeInteger(flags.rawValue)

        // Payload length (4 bytes, little endian)
        buffer.writeInteger(UInt32(payload.readableBytes), endianness: .little)

        // Payload (N bytes)
        var payloadCopy = payload
        buffer.writeBuffer(&payloadCopy)

        // CRC32 (4 bytes, little endian)
        let crc = Self.calculateCRC32(buffer: buffer)
        buffer.writeInteger(crc, endianness: .little)
    }

    public func encode() -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: Self.headerSize + payload.readableBytes)
        encode(into: &buffer)
        return buffer
    }

    public static func decode(from buffer: inout ByteBuffer) throws -> ProtocolFrame {
        guard buffer.readableBytes >= headerSize else {
            throw ProtocolError.insufficientData(expected: headerSize, got: buffer.readableBytes)
        }

        let readerIndex = buffer.readerIndex

        guard let versionByte = buffer.readInteger(as: UInt8.self) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to read version")
        }
        let version = ProtocolVersion(byte: versionByte)

        guard version.isCompatible(with: .current) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.incompatibleVersion(got: version, expected: .current)
        }

        guard let messageTypeRaw = buffer.readInteger(as: UInt8.self),
            let messageType = MessageType(rawValue: messageTypeRaw)
        else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Invalid message type")
        }

        guard let flagsRaw = buffer.readInteger(as: UInt8.self) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to read flags")
        }
        let flags = ProtocolFlags(rawValue: flagsRaw)

        guard let payloadLength = buffer.readInteger(endianness: .little, as: UInt32.self) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to read payload length")
        }
        guard payloadLength <= maxPayloadSize else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.payloadTooLarge(size: Int(payloadLength), max: Int(maxPayloadSize))
        }

        let totalRequired = Int(payloadLength) + 4
        guard buffer.readableBytes >= totalRequired else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.insufficientData(expected: totalRequired, got: buffer.readableBytes)
        }

        guard let payload = buffer.readSlice(length: Int(payloadLength)) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to read payload")
        }

        guard let crc = buffer.readInteger(endianness: .little, as: UInt32.self) else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to read CRC")
        }

        var dataForCRC = buffer
        dataForCRC.moveReaderIndex(to: readerIndex)
        guard let crcData = dataForCRC.readSlice(length: buffer.readerIndex - readerIndex - 4)
        else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.decodingFailed(reason: "Failed to extract CRC data")
        }

        let expectedCRC = calculateCRC32(buffer: crcData)
        guard crc == expectedCRC else {
            buffer.moveReaderIndex(to: readerIndex)
            throw ProtocolError.crcMismatch(expected: expectedCRC, got: crc)
        }

        return try ProtocolFrame(
            version: version,
            messageType: messageType,
            flags: flags,
            payload: payload
        )
    }

    private static func calculateCRC32(buffer: ByteBuffer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF

        buffer.withUnsafeReadableBytes { pointer in
            for byte in pointer {
                crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }

        return crc ^ 0xFFFF_FFFF
    }

    public var description: String {
        "ProtocolFrame(v\(version), type: \(messageType), flags: \(flags), payload: \(payload.readableBytes) bytes)"
    }
}

private let crc32Table: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var crc = UInt32(i)
        for _ in 0..<8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}()

public enum ProtocolError: Error, Sendable, CustomStringConvertible {
    case payloadTooLarge(size: Int, max: Int)
    case insufficientData(expected: Int, got: Int)
    case decodingFailed(reason: String)
    case incompatibleVersion(got: ProtocolVersion, expected: ProtocolVersion)
    case crcMismatch(expected: UInt32, got: UInt32)

    public var description: String {
        switch self {
        case .payloadTooLarge(let size, let max):
            return "Payload too large: \(size) bytes (max: \(max))"
        case .insufficientData(let expected, let got):
            return "Insufficient data: expected \(expected) bytes, got \(got)"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .incompatibleVersion(let got, let expected):
            return "Incompatible version: got \(got), expected \(expected)"
        case .crcMismatch(let expected, let got):
            return
                "CRC mismatch: expected \(String(format: "0x%08X", expected)), got \(String(format: "0x%08X", got))"
        }
    }
}
