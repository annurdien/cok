import Foundation
import Logging

public actor GracefulShutdown {
    public enum ShutdownSignal: Sendable {
        case interrupt
        case terminate
        case user(Int32)
    }
    
    public typealias ShutdownHandler = @Sendable () async throws -> Void
    
    private var handlers: [ShutdownHandler] = []
    private var isShuttingDown = false
    private let logger: Logger
    private let timeout: TimeInterval
    
    public init(logger: Logger, timeout: TimeInterval = 30) {
        self.logger = logger
        self.timeout = timeout
    }
    
    public func register(handler: @escaping ShutdownHandler) {
        handlers.append(handler)
    }
    
    public func shutdown(signal: ShutdownSignal) async {
        guard !isShuttingDown else {
            logger.warning("Shutdown already in progress")
            return
        }
        
        isShuttingDown = true
        logger.info("Graceful shutdown initiated", metadata: ["signal": "\(signal)"])
        
        let start = Date()
        
        for (index, handler) in handlers.enumerated() {
            do {
                try await withTimeout(seconds: timeout) {
                    try await handler()
                }
                logger.debug("Shutdown handler \(index + 1) completed")
            } catch {
                logger.error("Shutdown handler \(index + 1) failed", metadata: ["error": "\(error)"])
            }
        }
        
        let duration = Date().timeIntervalSince(start)
        logger.info("Graceful shutdown completed", metadata: ["duration": "\(String(format: "%.2f", duration))s"])
    }
    
    public var shuttingDown: Bool { isShuttingDown }
    
    private func withTimeout(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ShutdownError.timeout
            }
            
            try await group.next()
            group.cancelAll()
        }
    }
}

public enum ShutdownError: Error, Sendable {
    case timeout
    case interrupted
}

import Dispatch

nonisolated(unsafe) private var shutdownInstance: GracefulShutdown?
nonisolated(unsafe) private var sigintSource: DispatchSourceSignal?
nonisolated(unsafe) private var sigtermSource: DispatchSourceSignal?

public func setupSignalHandlers(shutdown: GracefulShutdown) {
    shutdownInstance = shutdown
    
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    
    sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource?.setEventHandler {
        Task {
            await shutdownInstance?.shutdown(signal: .interrupt)
            exit(0)
        }
    }
    sigintSource?.resume()
    
    sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource?.setEventHandler {
        Task {
            await shutdownInstance?.shutdown(signal: .terminate)
            exit(0)
        }
    }
    sigtermSource?.resume()
}
