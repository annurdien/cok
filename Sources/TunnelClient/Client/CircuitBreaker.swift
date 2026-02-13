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

    public func recordSuccess() {
        failureCount = 0
        state = .closed
        lastFailureTime = nil
    }

    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()

        if failureCount >= threshold {
            state = .open
        }
    }

    public func canAttempt() -> Bool {
        switch state {
        case .closed:
            return true
        case .halfOpen:
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

    public func getState() -> State {
        return state
    }

    public func getFailureCount() -> Int {
        return failureCount
    }

    public func reset() {
        state = .closed
        failureCount = 0
        lastFailureTime = nil
    }
}
