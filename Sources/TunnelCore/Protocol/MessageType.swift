import Foundation
import NIOCore

public enum MessageType: UInt8, Sendable, CaseIterable {
    case connectRequest = 0x01
    case connectResponse = 0x02
    case httpRequest = 0x10
    case httpResponse = 0x11
    case ping = 0x20
    case pong = 0x21
    case disconnect = 0x30
    case error = 0xFF
}

extension MessageType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectRequest: return "ConnectRequest"
        case .connectResponse: return "ConnectResponse"
        case .httpRequest: return "HTTPRequest"
        case .httpResponse: return "HTTPResponse"
        case .ping: return "Ping"
        case .pong: return "Pong"
        case .disconnect: return "Disconnect"
        case .error: return "Error"
        }
    }
}
