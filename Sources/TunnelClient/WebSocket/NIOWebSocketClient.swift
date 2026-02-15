#if canImport(FoundationNetworking)
// Linux-specific NIO-based WebSocket client
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import TunnelCore

final class NIOWebSocketClientHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let logger: Logger
    private let messageHandler: (@Sendable (ProtocolFrame) async -> Void)?
    private let onDisconnect: @Sendable () -> Void

    init(logger: Logger, messageHandler: (@Sendable (ProtocolFrame) async -> Void)?, onDisconnect: @escaping @Sendable () -> Void) {
        self.logger = logger
        self.messageHandler = messageHandler
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary:
            var buffer = frame.unmaskedData
            if let protocolFrame = try? ProtocolFrame.decode(from: &buffer) {
                if let handler = self.messageHandler {
                    Task {
                        await handler(protocolFrame)
                    }
                }
            }
        case .connectionClose:
            onDisconnect()
            context.close(promise: nil)
        case .ping:
            var frameData = frame.data
            var pongData = context.channel.allocator.buffer(capacity: frameData.readableBytes)
            pongData.writeBuffer(&frameData)
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("WebSocket error: \(error.localizedDescription)")
        onDisconnect()
        context.close(promise: nil)
    }
}

final class NIOWebSocketConnection: Sendable {
    let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    func send(_ frame: ProtocolFrame) async throws {
        let frameData = frame.encode()
        let wsFrame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
        try await channel.writeAndFlush(wsFrame)
    }

    func close() async throws {
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
        try await channel.writeAndFlush(closeFrame)
        try await channel.close()
    }
}
#endif
