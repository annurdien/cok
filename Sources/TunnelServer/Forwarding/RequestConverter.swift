import Foundation
import NIOCore
import NIOHTTP1
import TunnelCore

public struct RequestConverter: Sendable {
    public init() {}

    public func toProtocolMessage(
        head: HTTPRequestHead,
        body: ByteBuffer,
        remoteAddress: String
    ) -> HTTPRequestMessage {
        HTTPConversion.toRequestMessage(head: head, body: body, remoteAddress: remoteAddress)
    }

    public func toHTTPResponse(message: HTTPResponseMessage) -> (
        head: HTTPResponseHead, body: ByteBuffer?
    ) {
        HTTPConversion.toHTTPResponse(message: message)
    }
}
