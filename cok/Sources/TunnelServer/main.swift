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

let httpServer = HTTPServer(config: config, logger: logger)
let wsServer = WebSocketServer(config: config, logger: logger)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await httpServer.start()
    }

    group.addTask {
        try await wsServer.start()
    }

    try await group.next()
}
