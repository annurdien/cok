import Foundation

public struct ProtocolFlags: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let compressed = ProtocolFlags(rawValue: 1 << 0)

    public static let encrypted = ProtocolFlags(rawValue: 1 << 1)

    public static let requiresACK = ProtocolFlags(rawValue: 1 << 2)

    public var description: String {
        var flags: [String] = []
        if contains(.compressed) { flags.append("compressed") }
        if contains(.encrypted) { flags.append("encrypted") }
        if contains(.requiresACK) { flags.append("requiresACK") }
        return flags.isEmpty ? "none" : flags.joined(separator: "|")
    }
}
