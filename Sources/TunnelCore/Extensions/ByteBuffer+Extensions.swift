import Foundation
import NIOCore

extension ByteBuffer {
    // MARK: - String
    public mutating func writeStringWithLength(_ string: String) {
        let data = string.utf8
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    public mutating func readStringWithLength() -> String? {
        guard let length = readInteger(as: UInt32.self),
            let bytes = readSlice(length: Int(length)),
            let string = bytes.getString(at: 0, length: bytes.readableBytes)
        else {
            return nil
        }
        return string
    }

    public mutating func writeOptionalString(_ string: String?) {
        if let string = string {
            writeInteger(UInt8(1))
            writeStringWithLength(string)
        } else {
            writeInteger(UInt8(0))
        }
    }

    public mutating func readOptionalString() -> String? {
        guard let presence = readInteger(as: UInt8.self) else { return nil }
        if presence == 1 {
            return readStringWithLength()
        }
        return nil
    }

    // MARK: - UUID
    public mutating func writeUUID(_ uuid: UUID) {
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        writeBytes(uuidBytes)
    }

    public mutating func readUUID() -> UUID? {
        guard let bytes = readBytes(length: 16) else { return nil }
        let uuidTuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }

    // MARK: - Date
    public mutating func writeDate(_ date: Date) {
        writeInteger(date.timeIntervalSince1970.bitPattern)
    }

    public mutating func readDate() -> Date? {
        guard let bitPattern = readInteger(as: UInt64.self) else { return nil }
        return Date(timeIntervalSince1970: Double(bitPattern: bitPattern))
    }

    // MARK: - Array
    public mutating func writeArray<T>(_ array: [T], writeElement: (inout ByteBuffer, T) -> Void) {
        writeInteger(UInt32(array.count))
        for element in array {
            writeElement(&self, element)
        }
    }

    public mutating func readArray<T>(readElement: (inout ByteBuffer) -> T?) -> [T]? {
        guard let count = readInteger(as: UInt32.self) else { return nil }
        var array: [T] = []
        array.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let element = readElement(&self) else { return nil }
            array.append(element)
        }
        return array
    }

    // MARK: - Data
    public mutating func writeDataWithLength(_ data: Data) {
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    public mutating func readDataWithLength() -> Data? {
        guard let length = readInteger(as: UInt32.self),
            let bytes = readBytes(length: Int(length))
        else {
            return nil
        }
        return Data(bytes)
    }
}
