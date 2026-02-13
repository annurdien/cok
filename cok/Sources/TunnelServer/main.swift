import Foundation
import Logging

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

let httpServer = HTTPServer(config: config, logger: logger, connectionManager: connectionManager)
let wsServer = WebSocketServer(
    config: config, logger: logger, connectionManager: connectionManager, authService: authService)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await httpServer.start()
    }

    group.addTask {
        try await wsServer.start()
    }

    try await group.next()
}
