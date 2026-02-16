import Foundation
import Logging
@preconcurrency import NIOCore
import NIOPosix
import TunnelCore

public actor TunnelTCPClient {
    public enum State: String, Sendable, CustomStringConvertible {
        case disconnected
        case connecting
        case connected
        case disconnecting

        public var description: String { rawValue }
    }

    private let config: ClientConfig
    private let logger: Logger
    private let group: EventLoopGroup
    private var channel: Channel?
    private var state: State = .disconnected
    private var messageHandler: ((ProtocolFrame) async -> Void)?

    public init(config: ClientConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting

        logger.info(
            "Connecting to tunnel server",
            metadata: [
                "host": "\(config.serverHost)",
                "port": "\(config.serverPort)",
            ])

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

            logger.info("Connected to tunnel server")

            try await sendConnectRequest()

            channel.closeFuture.whenComplete { [weak self] (_: Result<Void, Error>) in
                Task { [weak self] in
                    await self?.handleClose()
                }
            }

        } catch {
            state = .disconnected
            logger.error("Failed to connect", metadata: ["error": "\(error)"])
            throw error
        }
    }

    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnecting

        try? await channel?.close()
        channel = nil
        state = .disconnected
    }

    public func sendFrame(_ frame: ProtocolFrame) async throws {
        guard let channel = channel else {
            throw ClientError.connectionFailed("Not connected")
        }
        try await channel.writeAndFlush(frame).get()
    }

    public func onMessage(_ handler: @escaping (ProtocolFrame) async -> Void) {
        self.messageHandler = handler
    }

    public func getState() -> State {
        return state
    }

    public func isConnected() -> Bool {
        return state == .connected
    }

    nonisolated func handleIncomingFrame(_ frame: ProtocolFrame) {
        Task {
            await self._handleIncomingFrame(frame)
        }
    }

    private func _handleIncomingFrame(_ frame: ProtocolFrame) async {
        await messageHandler?(frame)
    }

    private func handleClose() {
        if state != .disconnected {
            logger.warning("Connection closed")
            state = .disconnected
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
