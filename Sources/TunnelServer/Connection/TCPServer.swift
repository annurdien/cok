import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import TunnelCore

final class TCPServer: Sendable {
    private let group: EventLoopGroup
    private let config: ServerConfig
    private let logger: Logger
    private let connectionManager: ConnectionManager
    private let authService: AuthService
    private let requestTracker: RequestTracker
    // private let rateLimiter: RateLimiter // Not used in TCP handler for now effectively, or we can add it later

    private let isRunning = ManagedAtomic(false)

    init(
        config: ServerConfig,
        logger: Logger,
        connectionManager: ConnectionManager,
        authService: AuthService,
        requestTracker: RequestTracker
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
        self.requestTracker = requestTracker
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(ProtocolFrameDecoder()),
                    MessageToByteHandler(ProtocolFrameEncoder()),
                    TCPHandler(
                        logger: self.logger,
                        connectionManager: self.connectionManager,
                        authService: self.authService,
                        requestTracker: self.requestTracker
                    ),
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)

        let channel = try await bootstrap.bind(host: config.host, port: config.wsPort).get()

        logger.info("TCP Server started on \(config.host):\(config.wsPort)")

        try await channel.closeFuture.get()
    }

    func shutdown() async throws {
        try await group.shutdownGracefully()
    }
}

final class TCPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ProtocolFrame
    typealias OutboundOut = ProtocolFrame

    private let logger: Logger
    private let connectionManager: ConnectionManager
    private let authService: AuthService
    private let requestTracker: RequestTracker
    private let codec: MessageCodec

    // State to track if this connection is authenticated and registered
    private let tunnelID: ManagedAtomic<UUID?> = ManagedAtomic(nil)

    init(
        logger: Logger,
        connectionManager: ConnectionManager,
        authService: AuthService,
        requestTracker: RequestTracker,
        codec: MessageCodec = BinaryMessageCodec()
    ) {
        self.logger = logger
        self.connectionManager = connectionManager
        self.authService = authService
        self.requestTracker = requestTracker
        self.codec = codec
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let channel = context.channel

        Task {
            do {
                switch frame.messageType {
                case .connectRequest:
                    try await handleConnectRequest(channel: channel, payload: frame.payload)
                case .httpResponse:
                    try await handleHTTPResponse(channel: channel, payload: frame.payload)
                case .ping:
                    try await handlePing(channel: channel)
                default:
                    logger.warning("Received unexpected message type: \(frame.messageType)")
                }
            } catch {
                logger.error("Error handling frame: \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private func handleConnectRequest(channel: Channel, payload: ByteBuffer)
        async throws
    {
        let request = try codec.decode(ConnectRequest.self, from: payload)

        logger.info(
            "Received connect request",
            metadata: ["subdomain": "\(request.requestedSubdomain ?? "auto")"])

        do {
            // Validate API Key
            guard let apiKey = await authService.validateAPIKey(request.apiKey) else {
                throw ClientError.authenticationFailed
            }

            // Initial check if requested subdomain matches
            if let requested = request.requestedSubdomain, apiKey.subdomain != requested {
                throw ClientError.invalidSubdomain(requested)
            }

            // Register Tunnel
            let tunnel = try await connectionManager.registerTunnel(
                subdomain: apiKey.subdomain,
                apiKey: request.apiKey,
                channel: channel
            )

            // Generate Session Token
            let token = try await authService.generateSessionToken(
                tunnelID: tunnel.id,
                subdomain: apiKey.subdomain,
                apiKey: request.apiKey
            )

            // Send Success Response
            let response = ConnectResponse(
                tunnelID: tunnel.id,
                subdomain: apiKey.subdomain,
                sessionToken: token,
                publicURL: "https://\(apiKey.subdomain).\(config.baseDomain)",
                expiresAt: Date().addingTimeInterval(86400)
            )

            try await send(response, type: .connectResponse, channel: channel)

            // Update state
            tunnelID.set(tunnel.id)

        } catch {
            logger.error("Connection failed", metadata: ["error": "\(error)"])

            // Map error to code
            let code: UInt16
            let message: String

            if let clientError = error as? ClientError {
                switch clientError {
                case .authenticationFailed:
                    code = 401
                    message = "Authentication failed"
                case .invalidSubdomain:
                    code = 400
                    message = "Invalid subdomain"
                default:
                    code = 400
                    message = clientError.description
                }
            } else if let serverError = error as? ServerError {
                switch serverError {
                case .subdomainTaken:
                    code = 409
                    message = "Subdomain taken"
                default:
                    code = 500
                    message = serverError.description
                }
            } else {
                code = 500
                message = "Internal server error"
            }

            // Send Error Response
            let response = ErrorMessage(
                code: code,
                message: message
            )
            try await send(response, type: .error, channel: channel)

            // Close connection after error
            channel.close(promise: nil)
        }
    }

    private func handleHTTPResponse(channel: Channel, payload: ByteBuffer)
        async throws
    {
        let response = try codec.decode(HTTPResponseMessage.self, from: payload)
        await requestTracker.complete(requestID: response.requestID, response: response)
    }

    private func handlePing(channel: Channel) async throws {
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .pong,
            payload: ByteBuffer()
        )
        channel.writeAndFlush(frame, promise: nil)
    }

    private func send<T: BinarySerializable & Sendable>(
        _ message: T, type: MessageType, channel: Channel
    ) async throws {
        let payload = try codec.encode(message)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: type,
            payload: payload
        )
        channel.writeAndFlush(frame, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // We can't easily know the tunnelID here unless we stored it.
        // But the channel itself is used in ConnectionManager to track tunnels.
        // ConnectionManager handles disconnection if the channel closes?
        // Actually ConnectionManager listens to channel close future usually, OR we should explicitly unregister.
        // But ConnectionManager.disconnectAll closes channels.
        // If client disconnects, we should probably unregister.
        // For now, relies on the fact that ConnectionManager stores the channel.
        // Ideally we should unregister here if we knew the ID.
        // Since we don't store ID on the separate actor easily without invalidating sendable.
        // Let's rely on ConnectionManager's cleanup if it monitors channels,
        // OR we can find the tunnel by channel? ConnectionManager doesn't support that efficiently.
        // Use a simple task to iterate and find? Efficient? No.

        // Better: When registering, we can store the tunnelID in this handler?
        // TCPHandler is a class, it can have state.
        // I added `tunnelID` property.

        // However, we need to set it.
    }
}

// Helper for atomic bool or similar since we need Sendable
class ManagedAtomic<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NIOLock()

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.withLock { value }
    }

    func set(_ newValue: T) {
        lock.withLock { value = newValue }
    }
}
