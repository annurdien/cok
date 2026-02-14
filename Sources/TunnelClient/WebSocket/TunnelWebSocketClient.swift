import Foundation
import Logging
import NIOCore
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
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts: Int = 0
    private var isShuttingDown: Bool = false
    private var messageHandler: (@Sendable (ProtocolFrame) async -> Void)?
    private var receiveTask: Task<Void, Never>?

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

            // Start receiving messages
            receiveTask = Task { [weak self] in
                await self?.receiveMessages()
            }

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

        var request = URLRequest(url: url)
        request.setValue(config.subdomain, forHTTPHeaderField: "X-Subdomain")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        
        task.resume()

        // Send initial connect request
        try await sendConnectRequest()
    }
    
    private func receiveMessages() async {
        while !isShuttingDown && state == .connected {
            do {
                guard let task = webSocketTask else { break }
                let message = try await task.receive()
                
                switch message {
                case .data(let data):
                    var buffer = ByteBuffer.from(data)
                    if let frame = try? ProtocolFrame.decode(from: &buffer) {
                        await handleIncomingFrame(frame)
                    }
                case .string:
                    logger.warning("Received unexpected text message")
                @unknown default:
                    break
                }
            } catch {
                if !isShuttingDown {
                    logger.error("Error receiving message", metadata: [
                        "error": "\(error.localizedDescription)"
                    ])
                    
                    state = .disconnected
                    Task {
                        try? await self.scheduleReconnect()
                    }
                }
                break
            }
        }
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
        
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
        }

        logger.info("Disconnected from tunnel server")
    }

    public func sendFrame(_ frame: ProtocolFrame) async throws {
        guard let task = webSocketTask, state == .connected else {
            throw TunnelError.client(.connectionFailed("Not connected"), context: ErrorContext(component: "WebSocketClient"))
        }

        let frameData = frame.encode().toData()
        let message = URLSessionWebSocketTask.Message.data(frameData)
        
        try await task.send(message)
    }

    public func onMessage(handler: @escaping @Sendable (ProtocolFrame) async -> Void) {
        self.messageHandler = handler
    }

    private func handleIncomingFrame(_ frame: ProtocolFrame) async {
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

        let frameData = frame.encode().toData()
        let message = URLSessionWebSocketTask.Message.data(frameData)
        
        try await webSocketTask?.send(message)

        logger.debug("Sent connect request", metadata: [
            "subdomain": "\(config.subdomain)"
        ])
    }
}

// MARK: - ByteBuffer Extension for Data conversion
extension ByteBuffer {
    func toData() -> Data {
        return Data(self.readableBytesView)
    }
    
    static func from(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}
