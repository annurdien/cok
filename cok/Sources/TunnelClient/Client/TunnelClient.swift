import Foundation
import Logging
import TunnelCore

public actor TunnelClient {
    private let config: ClientConfig
    private let logger: Logger
    private let websocketClient: TunnelWebSocketClient
    private let circuitBreaker: CircuitBreaker
    private let requestHandler: LocalRequestHandler
    private let localProxy: LocalHTTPProxy
    private var isRunning: Bool = false

    public init(config: ClientConfig, logger: Logger) throws {
        try config.validate()

        self.config = config
        self.logger = logger

        self.websocketClient = TunnelWebSocketClient(config: config, logger: logger)
        self.circuitBreaker = CircuitBreaker(
            threshold: config.circuitBreakerThreshold,
            timeout: config.circuitBreakerTimeout
        )

        self.requestHandler = LocalRequestHandler(
            websocketClient: websocketClient,
            circuitBreaker: circuitBreaker,
            config: config,
            logger: logger
        )

        self.localProxy = LocalHTTPProxy(
            config: config,
            requestHandler: requestHandler,
            logger: logger
        )
    }

    private func setupMessageHandling() async {
        await websocketClient.onMessage { [weak self] frame in
            guard let self = self else { return }
            await self.requestHandler.handleIncomingMessage(frame)
        }
    }

    public func start() async throws {
        await setupMessageHandling()
        
        guard !isRunning else {
            logger.warning("Client is already running")
            return
        }

        isRunning = true

        logger.info("Starting Cok tunnel client", metadata: [
            "server": "\(config.serverURL)",
            "subdomain": "\(config.subdomain)",
            "localPort": "\(config.localPort)"
        ])

        try await localProxy.start()

        try await websocketClient.connect()

        logger.info("Cok tunnel client is running", metadata: [
            "publicURL": "https://\(config.subdomain).tunnel.example.com",
            "localURL": "http://\(config.localHost):\(config.localPort)"
        ])
    }

    public func stop() async throws {
        guard isRunning else {
            logger.warning("Client is not running")
            return
        }

        isRunning = false

        logger.info("Stopping Cok tunnel client")

        await websocketClient.disconnect()
        try await localProxy.stop()

        logger.info("Cok tunnel client stopped")
    }

    public func getStatus() async -> ClientStatus {
        let websocketState = await websocketClient.getState()
        let circuitBreakerState = await circuitBreaker.getState()
        let pendingRequests = await requestHandler.pendingCount()

        return ClientStatus(
            isRunning: isRunning,
            websocketState: websocketState,
            circuitBreakerState: circuitBreakerState,
            pendingRequests: pendingRequests,
            config: config
        )
    }
}

public struct ClientStatus: Sendable {
    public let isRunning: Bool
    public let websocketState: TunnelWebSocketClient.State
    public let circuitBreakerState: CircuitBreaker.State
    public let pendingRequests: Int
    public let config: ClientConfig

    public var description: String {
        """
        Cok Tunnel Client Status
        ========================
        Running: \(isRunning)
        WebSocket: \(websocketState)
        Circuit Breaker: \(circuitBreakerState)
        Pending Requests: \(pendingRequests)
        
        Configuration:
        - Server: \(config.serverURL)
        - Subdomain: \(config.subdomain)
        - Local: \(config.localHost):\(config.localPort)
        """
    }
}
