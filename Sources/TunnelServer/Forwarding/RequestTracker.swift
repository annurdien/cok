import Foundation
import Logging
import TunnelCore

public actor RequestTracker {
    private struct PendingRequest {
        let continuation: CheckedContinuation<HTTPResponseMessage, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [UUID: PendingRequest] = [:]
    private let timeout: TimeInterval
    private let logger: Logger

    public init(timeout: TimeInterval = 30.0, logger: Logger) {
        self.timeout = timeout
        self.logger = logger
    }

    public func track(requestID: UUID) async throws -> HTTPResponseMessage {
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return
                }
                await self.expire(requestID: requestID)
            }

            pending[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            logger.debug(
                "Tracking request",
                metadata: [
                    "requestID": "\(requestID.uuidString.prefix(8))",
                    "timeout": "\(timeout)s",
                ]
            )
        }
    }

    public func complete(requestID: UUID, response: HTTPResponseMessage) {
        guard let entry = pending.removeValue(forKey: requestID) else {
            logger.warning(
                "Response for unknown request",
                metadata: ["requestID": "\(requestID.uuidString.prefix(8))"]
            )
            return
        }

        entry.timeoutTask.cancel()

        logger.debug(
            "Request completed",
            metadata: [
                "requestID": "\(requestID.uuidString.prefix(8))",
                "status": "\(response.statusCode)",
            ]
        )

        entry.continuation.resume(returning: response)
    }

    public func fail(requestID: UUID, error: Error) {
        guard let entry = pending.removeValue(forKey: requestID) else {
            logger.warning(
                "Failure for unknown request",
                metadata: ["requestID": "\(requestID.uuidString.prefix(8))"]
            )
            return
        }

        entry.timeoutTask.cancel()

        logger.error(
            "Request failed",
            metadata: [
                "requestID": "\(requestID.uuidString.prefix(8))",
                "error": "\(error.localizedDescription)",
            ]
        )

        entry.continuation.resume(throwing: error)
    }

    public func pendingCount() -> Int {
        pending.count
    }

    private func expire(requestID: UUID) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }

        logger.warning(
            "Request timed out",
            metadata: ["requestID": "\(requestID.uuidString.prefix(8))"]
        )

        entry.continuation.resume(
            throwing: TunnelError.client(
                .timeout,
                context: ErrorContext(component: "RequestTracker")
            )
        )
    }
}
