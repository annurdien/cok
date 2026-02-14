import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
@preconcurrency import NIOWebSocket
import TunnelCore

public actor TunnelWebSocketClient {
    public enum State: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private let config: ClientConfig
    private let logger: Logger
    private var state: State = .disconnected
    private var channel: Channel?
    private var reconnectAttempts: Int = 0
    private var isShuttingDown: Bool = false
    private var messageHandler: (@Sendable (ProtocolFrame) async -> Void)?

    public init(config: ClientConfig, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    public func connect() async throws {
        guard !isShuttingDown else {
            throw TunnelError.client(.connectionFailed("Client is shutting down"), context: ErrorContext(component: "WebSocketClient"))
        }

        guard state != .connected, state != .connecting else {
            logger.warning("Already connected or connecting")
            return
        }

        state = .connecting
        reconnectAttempts += 1

        logger.info("Connecting to tunnel server", metadata: [
            "server": "\(config.serverURL)",
            "subdomain": "\(config.subdomain)",
            "attempt": "\(reconnectAttempts)"
        ])

        do {
            try await performConnect()
            reconnectAttempts = 0
            state = .connected

            logger.info("Successfully connected to tunnel server", metadata: [
                "subdomain": "\(config.subdomain)"
            ])
        } catch {
            state = .disconnected

            logger.error("Failed to connect", metadata: [
                "error": "\(error.localizedDescription)",
                "attempt": "\(reconnectAttempts)"
            ])

            if config.maxReconnectAttempts == -1 || reconnectAttempts < config.maxReconnectAttempts {
                try await scheduleReconnect()
            } else {
                throw error
            }
        }
    }

    private func performConnect() async throws {
        guard let url = URL(string: config.serverURL) else {
            throw TunnelError.client(.invalidRequest("Invalid server URL"), context: ErrorContext(component: "WebSocketClient"))
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let httpHandler = HTTPInitialRequestHandler(
                    host: url.host ?? "localhost",
                    path: url.path.isEmpty ? "/" : url.path,
                    headers: [
                        ("X-Subdomain", self.config.subdomain),
                        ("X-API-Key", self.config.apiKey)
                    ]
                )

                let websocketUpgrader = NIOWebSocketClientUpgrader(
                    maxFrameSize: 1 << 24,
                    automaticErrorHandling: true,
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(WebSocketFrameHandler(client: self))
                    }
                )

                return channel.pipeline.addHTTPClientHandlers(
                    leftOverBytesStrategy: .forwardBytes,
                    withClientUpgrade: (
                        upgraders: [websocketUpgrader],
                        completionHandler: { _ in }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        let host = url.host ?? "localhost"
        let port = url.port ?? (url.scheme == "wss" ? 443 : 80)

        self.channel = try await bootstrap.connect(host: host, port: port).get()

        try await sendConnectRequest()
    }

    private func sendConnectRequest() async throws {
        let connectMsg = ConnectRequest(
            apiKey: config.apiKey,
            requestedSubdomain: config.subdomain,
            clientVersion: "0.1.0",
            capabilities: ["http/1.1"]
        )

        let payload = try JSONEncoder().encode(connectMsg)
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeBytes(payload)

        let frame = try ProtocolFrame(
            version: .current,
            messageType: .connectRequest,
            flags: [],
            payload: buffer
        )

        let frameData = frame.encode()
        let wsFrame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            data: frameData
        )

        try await channel?.writeAndFlush(wsFrame).get()

        logger.debug("Sent connect request", metadata: [
            "subdomain": "\(config.subdomain)"
        ])
    }

    private func scheduleReconnect() async throws {
        guard !isShuttingDown else { return }

        state = .reconnecting
        let delay = config.reconnectDelay

        logger.info("Scheduling reconnect", metadata: [
            "delay": "\(delay)s",
            "attempt": "\(reconnectAttempts)"
        ])

        try await Task.sleep(for: .seconds(delay))

        if !isShuttingDown {
            try await connect()
        }
    }

    public func disconnect() async {
        isShuttingDown = true
        state = .disconnected

        if let channel = channel {
            try? await channel.close().get()
            self.channel = nil
        }

        logger.info("Disconnected from tunnel server")
    }

    public func sendFrame(_ frame: ProtocolFrame) async throws {
        guard let channel = channel, state == .connected else {
            throw TunnelError.client(.connectionFailed("Not connected"), context: ErrorContext(component: "WebSocketClient"))
        }

        let frameData = frame.encode()
        let wsFrame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            data: frameData
        )

        try await channel.writeAndFlush(wsFrame).get()
    }

    public func onMessage(handler: @escaping @Sendable (ProtocolFrame) async -> Void) {
        self.messageHandler = handler
    }

    nonisolated func handleIncomingFrame(_ frame: ProtocolFrame) {
        Task {
            await self._handleIncomingFrame(frame)
        }
    }

    private func _handleIncomingFrame(_ frame: ProtocolFrame) async {
        guard let handler = messageHandler else {
            logger.warning("No message handler registered")
            return
        }

        await handler(frame)
    }

    public func getState() -> State {
        return state
    }

    public func isConnected() -> Bool {
        return state == .connected
    }
}

final class HTTPInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let path: String
    private let headers: [(String, String)]

    init(host: String, path: String, headers: [(String, String)]) {
        self.host = host
        self.path = path
        self.headers = headers
    }

    func channelActive(context: ChannelHandlerContext) {
        var httpHeaders = HTTPHeaders()
        httpHeaders.add(name: "Host", value: host)
        httpHeaders.add(name: "Connection", value: "Upgrade")
        httpHeaders.add(name: "Upgrade", value: "websocket")
        httpHeaders.add(name: "Sec-WebSocket-Version", value: "13")

        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path,
            headers: httpHeaders
        )

        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)

        switch response {
        case .head(let head):
            if head.status == .switchingProtocols {
                context.pipeline.removeHandler(self, promise: nil)
            }
        case .body, .end:
            break
        }
    }
}

final class WebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let client: TunnelWebSocketClient

    init(client: TunnelWebSocketClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        guard frame.opcode == .binary else {
            return
        }

        var buffer = frame.unmaskedData

        do {
            let protocolFrame = try ProtocolFrame.decode(from: &buffer)
            client.handleIncomingFrame(protocolFrame)
        } catch {
            context.fireErrorCaught(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
