import Foundation

public struct ProtocolVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: UInt8

    public let minor: UInt8

    public static let current = ProtocolVersion(major: 1, minor: 0)

    public static let minimum = ProtocolVersion(major: 1, minor: 0)

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public init(byte: UInt8) {
        self.major = byte >> 4
        self.minor = byte & 0x0F
    }

    public var byte: UInt8 {
        (major << 4) | (minor & 0x0F)
    }

    public func isCompatible(with other: ProtocolVersion) -> Bool {
        major == other.major
    }

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        return lhs.minor < rhs.minor
    }
}
