import Foundation
import Logging
import TunnelCore

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .info
    return handler
}

let logger = Logger(label: "cok.server")
let config: ServerConfig
do {
    config = try ServerConfig.fromEnvironment()
} catch {
    logger.critical("Server configuration error: \(error)")
    exit(1)
}

logger.info(
    "Starting Cok Server",
    metadata: [
        "httpPort": "\(config.httpPort)",
        "wsPort": "\(config.wsPort)",
    ])

let connectionManager = ConnectionManager(maxConnections: config.maxTunnels, logger: logger)
let authService = AuthService(secret: config.apiKeySecret)

if let testSubdomain = ProcessInfo.processInfo.environment["TEST_SUBDOMAIN"] {
    do {
        let testKey = try await authService.createAPIKey(for: testSubdomain)
        logger.info(
            "Test API key created",
            metadata: [
                "subdomain": "\(testSubdomain)",
                "key": "\(testKey.key)",
            ])

        let keyFilePath = FileManager.default.currentDirectoryPath + "/.api_key.tmp"
        try? testKey.key.write(toFile: keyFilePath, atomically: true, encoding: .utf8)
    } catch {
        logger.warning("Failed to create test API key", metadata: ["error": "\(error)"])
    }
}

let requestTracker = RequestTracker(timeout: 30.0, logger: logger)
let httpRateLimiter = RateLimiter(configuration: .http)
let healthChecker = HealthChecker(version: "0.1.0")

let httpServer = HTTPServer(
    config: config,
    logger: logger,
    connectionManager: connectionManager,
    requestTracker: requestTracker,
    rateLimiter: httpRateLimiter,
    healthChecker: healthChecker
)

let tcpServer = TCPServer(
    config: config,
    logger: logger,
    connectionManager: connectionManager,
    authService: authService,
    requestTracker: requestTracker
)

let shutdown = GracefulShutdown(logger: logger, timeout: 30)

await shutdown.register {
    logger.info("Shutting down HTTP server...")
    try await httpServer.shutdown()
}

await shutdown.register {
    logger.info("Shutting down TCP server...")
    try await tcpServer.shutdown()
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
        try await tcpServer.start()
    }

    do {
        try await group.next()
    } catch {
        logger.error("Server exited with error", metadata: ["error": "\(error)"])
        group.cancelAll()
        try? await group.waitForAll()
        throw error
    }
    group.cancelAll()
    try? await group.waitForAll()
}
