import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public final class WebSocketServer: Sendable {
    private let config: ServerConfig
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private let connectionManager: ConnectionManager
    private let authService: AuthService

    public init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        authService: AuthService
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, req in
                        channel.pipeline.addHandler(
                            WebSocketHandler(
                                config: self.config,
                                logger: self.logger,
                                connectionManager: self.connectionManager,
                                authService: self.authService
                            )
                        )
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    )
                )
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: config.wsPort).get()
        logger.info(
            "WebSocket server listening",
            metadata: [
                "port": "\(config.wsPort)",
                "address": "\(channel.localAddress?.description ?? "unknown")",
            ])

        try await channel.closeFuture.get()
    }

    public func shutdown() async throws {
        try await group.shutdownGracefully()
    }
}

final class WebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let config: ServerConfig
    private let logger: Logger
    private let connectionManager: ConnectionManager
    private let authService: AuthService
    private var tunnelID: UUID?

    init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        authService: AuthService
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.info(
            "WebSocket client connected",
            metadata: [
                "address": "\(context.remoteAddress?.description ?? "unknown")"
            ])
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let tunnelID = tunnelID {
            Task {
                await connectionManager.unregisterTunnel(id: tunnelID)
            }
        }
        logger.info("WebSocket client disconnected")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary:
            Task {
                await handleBinaryFrame(context: context, frame: frame)
            }

        case .text:
            handleTextFrame(context: context, frame: frame)

        case .connectionClose:
            context.close(promise: nil)

        case .ping:
            let pongData = frame.unmaskedData
            let pongFrame = WebSocketFrame(
                fin: true,
                opcode: .pong,
                data: pongData
            )
            context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)

        default:
            break
        }
    }

    private func handleBinaryFrame(context: ChannelHandlerContext, frame: WebSocketFrame) async {
        let data = frame.unmaskedData
        logger.debug(
            "Received binary frame",
            metadata: [
                "size": "\(data.readableBytes)"
            ])
    }

    private func handleTextFrame(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var data = frame.unmaskedData
        if let text = data.readString(length: data.readableBytes) {
            logger.debug(
                "Received text frame",
                metadata: [
                    "text": "\(text)"
                ])
        }
    }
}
