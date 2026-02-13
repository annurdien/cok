import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
@preconcurrency import NIOWebSocket
import TunnelCore

public final class WebSocketServer: Sendable {
    private let config: ServerConfig
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private let connectionManager: ConnectionManager
    private let authService: AuthService
    private let requestTracker: RequestTracker
    private let rateLimiter: RateLimiter

    public init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        authService: AuthService, requestTracker: RequestTracker, rateLimiter: RateLimiter
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(
                            WebSocketHandler(
                                config: self.config,
                                logger: self.logger,
                                connectionManager: self.connectionManager,
                                authService: self.authService,
                                requestTracker: self.requestTracker,
                                rateLimiter: self.rateLimiter
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
    private let requestTracker: RequestTracker
    private let rateLimiter: RateLimiter
    private let codec: MessageCodec
    private var tunnelID: UUID?

    init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        authService: AuthService, requestTracker: RequestTracker, rateLimiter: RateLimiter
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
        self.codec = JSONMessageCodec()
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
            let ctx = context
            let eventLoop = context.eventLoop
            let handler = self
            Task {
                await handler.handleBinaryFrame(context: ctx, eventLoop: eventLoop, frame: frame)
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

    private func handleBinaryFrame(context: ChannelHandlerContext, eventLoop: EventLoop, frame: WebSocketFrame) async {
        do {
            var data = frame.unmaskedData
            let protocolFrame = try ProtocolFrame.decode(from: &data)

            logger.debug(
                "Received protocol frame",
                metadata: [
                    "type": "\(protocolFrame.messageType)",
                    "size": "\(protocolFrame.payload.readableBytes)",
                ])

            switch protocolFrame.messageType {
            case .httpResponse:
                let response = try codec.decode(
                    HTTPResponseMessage.self, from: protocolFrame.payload)
                await requestTracker.complete(requestID: response.requestID, response: response)

            case .connectRequest:
                try await handleConnectRequest(
                    context: context, eventLoop: eventLoop, payload: protocolFrame.payload)

            case .ping:
                try handlePing(context: context, payload: protocolFrame.payload)

            case .error:
                let errorMsg = try codec.decode(ErrorMessage.self, from: protocolFrame.payload)
                logger.error(
                    "Received error from client",
                    metadata: [
                        "code": "\(errorMsg.code)",
                        "message": "\(errorMsg.message)",
                    ])

            default:
                logger.warning(
                    "Unexpected frame type",
                    metadata: [
                        "type": "\(protocolFrame.messageType)"
                    ])
            }
        } catch {
            logger.error(
                "Failed to decode protocol frame",
                metadata: [
                    "error": "\(error.localizedDescription)"
                ])
        }
    }

    private func handleConnectRequest(context: ChannelHandlerContext, eventLoop: EventLoop, payload: ByteBuffer) async
        throws {
        let clientIP = context.remoteAddress?.ipAddress ?? "unknown"

        guard await rateLimiter.tryConsume(identifier: clientIP) else {
            try await sendError(context: context, eventLoop: eventLoop, code: 429, message: "Rate limit exceeded")
            eventLoop.execute { context.close(promise: nil) }
            return
        }

        let request = try codec.decode(ConnectRequest.self, from: payload)

        let isValid = await authService.validateAPIKey(request.apiKey) != nil
        guard isValid else {
            try await sendError(context: context, eventLoop: eventLoop, code: 401, message: "Invalid API key")
            eventLoop.execute {
                context.close(promise: nil)
            }
            return
        }

        var subdomain = request.requestedSubdomain ?? UUID().uuidString.prefix(8).lowercased()

        if let requested = request.requestedSubdomain {
            if !SubdomainValidator.isValid(requested) {
                try await sendError(context: context, eventLoop: eventLoop, code: 400, message: "Invalid subdomain format")
                eventLoop.execute { context.close(promise: nil) }
                return
            }
            subdomain = requested
        }

        let tunnel = try await connectionManager.registerTunnel(
            subdomain: String(subdomain),
            apiKey: request.apiKey,
            channel: context.channel
        )

        self.tunnelID = tunnel.id

        let response = ConnectResponse(
            tunnelID: tunnel.id,
            subdomain: tunnel.subdomain,
            sessionToken: "session_\(UUID().uuidString)",
            publicURL: "http://\(tunnel.subdomain).\(config.baseDomain)",
            expiresAt: Date().addingTimeInterval(86400)
        )

        let responsePayload = try codec.encode(response)
        let responseFrame = try ProtocolFrame(
            version: .current,
            messageType: .connectResponse,
            flags: [],
            payload: responsePayload
        )

        let frameData = try responseFrame.encode()
        let wsFrame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
        eventLoop.execute {
            context.writeAndFlush(self.wrapOutboundOut(wsFrame), promise: nil)
        }

        logger.info(
            "Tunnel established",
            metadata: [
                "tunnelID": "\(tunnel.id.uuidString.prefix(8))",
                "subdomain": "\(tunnel.subdomain)",
            ])
    }

    private func handlePing(context: ChannelHandlerContext, payload: ByteBuffer) throws {
        let ping = try codec.decode(PingMessage.self, from: payload)
        let pong = PongMessage(pingTimestamp: ping.timestamp)

        let pongPayload = try codec.encode(pong)
        let pongFrame = try ProtocolFrame(
            version: .current,
            messageType: .pong,
            flags: [],
            payload: pongPayload
        )

        let frameData = try pongFrame.encode()
        let wsFrame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
        context.writeAndFlush(wrapOutboundOut(wsFrame), promise: nil)
    }

    private func sendError(context: ChannelHandlerContext, eventLoop: EventLoop, code: UInt16, message: String) async
        throws {
        let errorMsg = ErrorMessage(code: code, message: message)
        let payload = try codec.encode(errorMsg)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .error,
            flags: [],
            payload: payload
        )

        let frameData = try frame.encode()
        let wsFrame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
        eventLoop.execute {
            context.writeAndFlush(self.wrapOutboundOut(wsFrame), promise: nil)
        }
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
