import Foundation
import Logging
import TunnelCore

public actor RequestTracker {
    private var pending: [UUID: CheckedContinuation<HTTPResponseMessage, Error>] = [:]
    private let timeout: TimeInterval
    private let logger: Logger

    public init(timeout: TimeInterval = 30.0, logger: Logger) {
        self.timeout = timeout
        self.logger = logger
    }

    public func track(requestID: UUID) async throws -> HTTPResponseMessage {
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation

            logger.debug(
                "Tracking request",
                metadata: [
                    "requestID": "\(requestID.uuidString.prefix(8))",
                    "timeout": "\(timeout)s",
                ])

            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

                if let storedContinuation = pending.removeValue(forKey: requestID) {
                    logger.warning(
                        "Request timeout",
                        metadata: [
                            "requestID": "\(requestID.uuidString.prefix(8))"
                        ])
                    storedContinuation.resume(
                        throwing: TunnelError.client(
                            .timeout, context: ErrorContext(component: "RequestTracker")))
                }
            }
        }
    }

    public func complete(requestID: UUID, response: HTTPResponseMessage) {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            logger.warning(
                "Response for unknown request",
                metadata: [
                    "requestID": "\(requestID.uuidString.prefix(8))"
                ])
            return
        }

        logger.debug(
            "Request completed",
            metadata: [
                "requestID": "\(requestID.uuidString.prefix(8))",
                "status": "\(response.statusCode)",
            ])

        continuation.resume(returning: response)
    }

    public func fail(requestID: UUID, error: Error) {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            logger.warning(
                "Failure for unknown request",
                metadata: [
                    "requestID": "\(requestID.uuidString.prefix(8))"
                ])
            return
        }

        logger.error(
            "Request failed",
            metadata: [
                "requestID": "\(requestID.uuidString.prefix(8))",
                "error": "\(error.localizedDescription)",
            ])

        continuation.resume(throwing: error)
    }

    public func pendingCount() -> Int {
        return pending.count
    }
}
