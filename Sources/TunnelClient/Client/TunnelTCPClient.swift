import Foundation
import Logging
import NIOConcurrencyHelpers
@preconcurrency import NIOCore
import NIOPosix
import TunnelCore

/// Manages the persistent TCP connection from the tunnel client to the server.
///
/// Automatically reconnects on disconnection using exponential backoff, up to
/// `config.maxReconnectAttempts` times (-1 means unlimited).
public actor TunnelTCPClient {
    public enum State: String, Sendable, CustomStringConvertible {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case reconnecting

        public var description: String { rawValue }
    }

    private let config: ClientConfig
    private let logger: Logger
    private let group: EventLoopGroup
    private var channel: Channel?
    private var state: State = .disconnected
    private var messageHandler: ((ProtocolFrame) async -> Void)?
    private var reconnectAttempts: Int = 0

    public init(config: ClientConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    // MARK: - Public Interface

    public func connect() async throws {
        guard state == .disconnected else { return }
        reconnectAttempts = 0
        try await connectOnce()
    }

    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnecting

        try? await channel?.close()
        channel = nil
        state = .disconnected
    }

    public func sendFrame(_ frame: ProtocolFrame) async throws {
        guard let channel else {
            throw ClientError.connectionFailed("Not connected")
        }
        try await channel.writeAndFlush(frame).get()
    }

    public func onMessage(_ handler: @escaping (ProtocolFrame) async -> Void) {
        self.messageHandler = handler
    }

    public func getState() -> State { state }
    public func isConnected() -> Bool { state == .connected }

    // MARK: - Internal

    nonisolated func handleIncomingFrame(_ frame: ProtocolFrame) {
        Task { await self._handleIncomingFrame(frame) }
    }

    private func _handleIncomingFrame(_ frame: ProtocolFrame) async {
        await messageHandler?(frame)
    }

    // MARK: - Connection Lifecycle

    private func connectOnce() async throws {
        state = .connecting

        logger.info(
            "Connecting to tunnel server",
            metadata: [
                "host": "\(config.serverHost)",
                "port": "\(config.serverPort)",
            ]
        )

        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                .channelInitializer { channel in
                    let decoder = UncheckedInboundHandler(
                        ByteToMessageHandler(ProtocolFrameDecoder()))
                    let encoder = UncheckedOutboundHandler(
                        MessageToByteHandler(ProtocolFrameEncoder()))

                    return channel.pipeline.addHandler(decoder).flatMap {
                        channel.pipeline.addHandler(encoder)
                    }.flatMap {
                        channel.pipeline.addHandler(TCPClientHandler(actor: self))
                    }
                }

            let channel = try await bootstrap.connect(
                host: config.serverHost, port: config.serverPort
            ).get()
            self.channel = channel
            self.state = .connected
            self.reconnectAttempts = 0

            logger.info("Connected to tunnel server")

            try await sendConnectRequest()

            channel.closeFuture.whenComplete { [weak self] (_: Result<Void, Error>) in
                Task { [weak self] in await self?.handleClose() }
            }

        } catch {
            state = .disconnected
            logger.error("Failed to connect", metadata: ["error": "\(error)"])
            throw error
        }
    }

    private func handleClose() {
        guard state != .disconnected, state != .disconnecting else { return }

        logger.warning("Connection closed unexpectedly")
        channel = nil
        state = .disconnected

        Task { await scheduleReconnect() }
    }

    private func scheduleReconnect() async {
        let maxAttempts = config.maxReconnectAttempts
        guard maxAttempts == -1 || reconnectAttempts < maxAttempts else {
            logger.error(
                "Max reconnect attempts reached, giving up",
                metadata: ["attempts": "\(reconnectAttempts)"]
            )
            return
        }

        reconnectAttempts += 1
        state = .reconnecting

        // Exponential backoff: delay * 2^(attempt-1), capped at 60 seconds.
        let baseDelay = config.reconnectDelay
        let backoff = min(baseDelay * pow(2.0, Double(reconnectAttempts - 1)), 60.0)

        logger.info(
            "Reconnecting to tunnel server",
            metadata: [
                "attempt": "\(reconnectAttempts)",
                "delay": "\(String(format: "%.1f", backoff))s",
            ]
        )

        do {
            try await Task.sleep(for: .seconds(backoff))
        } catch {
            // Task cancelled (e.g. explicit disconnect) — abort reconnect.
            return
        }

        guard state == .reconnecting else { return }

        do {
            try await connectOnce()
        } catch {
            logger.warning(
                "Reconnect attempt failed",
                metadata: [
                    "attempt": "\(reconnectAttempts)",
                    "error": "\(error)",
                ]
            )
            await scheduleReconnect()
        }
    }

    private func sendConnectRequest() async throws {
        let request = ConnectRequest(
            apiKey: config.apiKey,
            requestedSubdomain: config.subdomain,
            clientVersion: "0.1.0"
        )

        let payload = try BinaryMessageCodec().encode(request)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .connectRequest,
            payload: payload
        )

        try await sendFrame(frame)
    }
}

final class TCPClientHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ProtocolFrame
    let actor: TunnelTCPClient

    init(actor: TunnelTCPClient) {
        self.actor = actor
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        actor.handleIncomingFrame(frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
