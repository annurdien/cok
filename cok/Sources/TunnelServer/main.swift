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

let httpServer = HTTPServer(
    config: config, logger: logger, connectionManager: connectionManager,
    requestTracker: requestTracker, rateLimiter: httpRateLimiter)
let wsServer = WebSocketServer(
    config: config, logger: logger, connectionManager: connectionManager, authService: authService,
    requestTracker: requestTracker, rateLimiter: wsRateLimiter)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await httpServer.start()
    }

    group.addTask {
        try await wsServer.start()
    }

    try await group.next()
}
