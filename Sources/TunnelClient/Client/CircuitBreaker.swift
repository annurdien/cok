import Foundation

public actor CircuitBreaker {
    public enum State: Sendable {
        case closed
        case open
        case halfOpen
    }

    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?
    private let threshold: Int
    private let timeout: TimeInterval

    public init(threshold: Int, timeout: TimeInterval) {
        self.threshold = threshold
        self.timeout = timeout
    }

    /// Attempts to acquire a permit to make a request.
    ///
    /// - Returns: `true` if the request should proceed, `false` if the circuit
    ///   is open and the timeout has not elapsed.
    ///
    /// Unlike a pure query, this method intentionally mutates state: it
    /// transitions `.open` → `.halfOpen` when the timeout has elapsed, marking
    /// that a probe attempt is in progress. Callers must follow up with either
    /// `recordSuccess()` or `recordFailure()`.
    public func tryAcquire() -> Bool {
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            guard let lastFailure = lastFailureTime else {
                state = .halfOpen
                return true
            }
            if Date().timeIntervalSince(lastFailure) >= timeout {
                state = .halfOpen
                return true
            }
            return false
        }
    }

    public func recordSuccess() {
        failureCount = 0
        state = .closed
        lastFailureTime = nil
    }

    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()

        // Re open immediately on any failure, including half open probe failures.
        // This prevents a single failed probe from leaving the breaker stuck in
        // .halfOpen while the failure count is already at or above threshold.
        if failureCount >= threshold || state == .halfOpen {
            state = .open
        }
    }

    public func getState() -> State { state }
    public func getFailureCount() -> Int { failureCount }

    public func reset() {
        state = .closed
        failureCount = 0
        lastFailureTime = nil
    }
}
