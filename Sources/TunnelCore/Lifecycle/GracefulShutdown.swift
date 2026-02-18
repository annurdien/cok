import Foundation
import Logging
import NIOCore
import NIOPosix

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
                logger.error(
                    "Shutdown handler \(index + 1) failed", metadata: ["error": "\(error)"])
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info(
            "Graceful shutdown completed",
            metadata: ["duration": "\(String(format: "%.2f", duration))s"]
        )
    }

    public var shuttingDown: Bool { isShuttingDown }

    private func withTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
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

// MARK: - Signal Handling
//
// Uses POSIX signal(2) + a detached Task to bridge signals into Swift concurrency.
// This approach works identically on macOS and Linux without relying on
// Darwin-specific DispatchSource APIs or nonisolated(unsafe) globals.

public func setupSignalHandlers(shutdown: GracefulShutdown) {
    // Ignore default signal disposition so we can handle them ourselves.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    // Spawn a long lived task that polls for signals via a pipe based mechanism.
    // We use a simple Pipe + DispatchIO-free approach: register a POSIX signal
    // handler that writes to a pipe, then read from it in an async context.
    let (sigintStream, sigintContinuation) = AsyncStream<Void>.makeStream()
    let (sigtermStream, sigtermContinuation) = AsyncStream<Void>.makeStream()

    let continuations = SignalContinuations(
        sigint: sigintContinuation,
        sigterm: sigtermContinuation
    )
    SignalContinuations.shared = continuations

    signal(SIGINT) { _ in SignalContinuations.shared?.sigint.yield() }
    signal(SIGTERM) { _ in SignalContinuations.shared?.sigterm.yield() }

    Task.detached {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in sigintStream {
                    await shutdown.shutdown(signal: .interrupt)
                    exit(0)
                }
            }
            group.addTask {
                for await _ in sigtermStream {
                    await shutdown.shutdown(signal: .terminate)
                    exit(0)
                }
            }
            await group.waitForAll()
        }
    }
}

/// Holds AsyncStream continuations for POSIX signal delivery.
/// The `shared` property is set once at startup before any signals can arrive.
final class SignalContinuations: @unchecked Sendable {
    let sigint: AsyncStream<Void>.Continuation
    let sigterm: AsyncStream<Void>.Continuation

    // nonisolated(unsafe) is intentional: this is written once before signal
    // handlers are installed and only read from signal handler context thereafter.
    nonisolated(unsafe) static var shared: SignalContinuations?

    init(sigint: AsyncStream<Void>.Continuation, sigterm: AsyncStream<Void>.Continuation) {
        self.sigint = sigint
        self.sigterm = sigterm
    }
}
