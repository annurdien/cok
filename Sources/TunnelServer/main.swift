import Foundation
import Logging
import TunnelCore

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .info
    return handler
}

let logger = Logger(label: "cok.server")
let config = ServerConfig.fromEnvironment()

logger.info(
    "Starting Cok Server",
    metadata: [
        "httpPort": "\(config.httpPort)",
        "wsPort": "\(config.wsPort)",
    ])

let connectionManager = ConnectionManager(maxConnections: config.maxTunnels, logger: logger)
let authService = AuthService(secret: config.apiKeySecret)
let requestTracker = RequestTracker(timeout: 30.0, logger: logger)
let httpRateLimiter = RateLimiter(configuration: .http)
let wsRateLimiter = RateLimiter(configuration: .websocket)
let metrics = MetricsCollector()
let healthChecker = HealthChecker(version: "0.1.0")

let httpServer = HTTPServer(
    config: config, logger: logger, connectionManager: connectionManager,
    requestTracker: requestTracker, rateLimiter: httpRateLimiter)
let wsServer = WebSocketServer(
    config: config, logger: logger, connectionManager: connectionManager, authService: authService,
    requestTracker: requestTracker, rateLimiter: wsRateLimiter)

let shutdown = GracefulShutdown(logger: logger, timeout: 30)

await shutdown.register {
    logger.info("Shutting down HTTP server...")
    try await httpServer.shutdown()
}

await shutdown.register {
    logger.info("Shutting down WebSocket server...")
    try await wsServer.shutdown()
}

await shutdown.register {
    logger.info("Cleaning up connections...")
    await connectionManager.disconnectAll()
}

setupSignalHandlers(shutdown: shutdown)

await healthChecker.registerUptimeCheck()
await healthChecker.register(name: "connections") {
    let count = await connectionManager.connectionCount()
    return .healthy("Active tunnels: \(count)")
}

logger.info("Signal handlers installed, server ready")

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await httpServer.start()
    }

    group.addTask {
        try await wsServer.start()
    }

    try await group.next()
}
