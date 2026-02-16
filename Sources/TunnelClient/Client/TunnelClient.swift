import Foundation
import Logging
import TunnelCore

public actor TunnelClient {
    private let config: ClientConfig
    private let logger: Logger
    private let tcpClient: TunnelTCPClient
    private let circuitBreaker: CircuitBreaker
    private let requestHandler: LocalRequestHandler
    private let localProxy: LocalHTTPProxy
    private var isRunning: Bool = false

    public init(config: ClientConfig, logger: Logger) throws {
        try config.validate()

        self.config = config
        self.logger = logger

        self.tcpClient = TunnelTCPClient(config: config, logger: logger)
        self.circuitBreaker = CircuitBreaker(
            threshold: config.circuitBreakerThreshold,
            timeout: config.circuitBreakerTimeout
        )

        self.requestHandler = LocalRequestHandler(
            tcpClient: tcpClient,
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
        await tcpClient.onMessage { [weak self] frame in
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

        logger.info(
            "Starting Cok tunnel client",
            metadata: [
                "server": "\(config.serverHost):\(config.serverPort)",
                "subdomain": "\(config.subdomain)",
                "localPort": "\(config.localPort)",
            ])

        // Note: LocalHTTPProxy not started - we forward incoming tunnel requests directly to local server

        try await tcpClient.connect()

        logger.info(
            "Cok tunnel client is running",
            metadata: [
                "publicURL": "https://\(config.subdomain).tunnel.example.com",  // This should come from connect response ideally
                "localURL": "http://\(config.localHost):\(config.localPort)",
            ])
    }

    public func stop() async throws {
        guard isRunning else {
            logger.warning("Client is not running")
            return
        }

        isRunning = false

        logger.info("Stopping Cok tunnel client")

        await tcpClient.disconnect()
        // Note: localProxy not used for reverse tunnel
        // try await localProxy.stop()

        logger.info("Cok tunnel client stopped")
    }

    public func getStatus() async -> ClientStatus {
        let tcpState = await tcpClient.getState()
        let circuitBreakerState = await circuitBreaker.getState()
        let pendingRequests = await requestHandler.pendingCount()

        return ClientStatus(
            isRunning: isRunning,
            tcpState: tcpState,
            circuitBreakerState: circuitBreakerState,
            pendingRequests: pendingRequests,
            config: config
        )
    }
}

public struct ClientStatus: Sendable {
    public let isRunning: Bool
    public let tcpState: TunnelTCPClient.State
    public let circuitBreakerState: CircuitBreaker.State
    public let pendingRequests: Int
    public let config: ClientConfig

    public var description: String {
        """
        Cok Tunnel Client Status
        ========================
        Running: \(isRunning)
        TCP Connection: \(tcpState)
        Circuit Breaker: \(circuitBreakerState)
        Pending Requests: \(pendingRequests)

        Configuration:
        - Server: \(config.serverHost):\(config.serverPort)
        - Subdomain: \(config.subdomain)
        - Local: \(config.localHost):\(config.localPort)
        """
    }
}
