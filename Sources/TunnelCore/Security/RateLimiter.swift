import Foundation

public actor RateLimiter {

    public struct Configuration: Sendable {
        public let capacity: Int
        public let refillRate: Double
        public let costPerRequest: Int

        public init(capacity: Int, refillRate: Double, costPerRequest: Int = 1) {
            self.capacity = capacity
            self.refillRate = refillRate
            self.costPerRequest = costPerRequest
        }

        public static let api = Configuration(capacity: 60, refillRate: 1.0)
        public static let connection = Configuration(capacity: 10, refillRate: 0.167)
        public static let http = Configuration(capacity: 120, refillRate: 2.0)
        public static let websocket = Configuration(capacity: 300, refillRate: 5.0)
    }

    private struct Bucket: Sendable {
        var tokens: Double
        var lastRefill: Date

        init(capacity: Int) {
            self.tokens = Double(capacity)
            self.lastRefill = Date()
        }
    }

    private let config: Configuration
    private var buckets: [String: Bucket] = [:]
    private let cleanupInterval: TimeInterval = 300
    private var lastCleanup = Date()

    public init(configuration: Configuration) {
        self.config = configuration
    }

    public func tryConsume(identifier: String) -> Bool {
        refillBucket(for: identifier)
        var bucket = buckets[identifier] ?? Bucket(capacity: config.capacity)
        let cost = Double(config.costPerRequest)

        guard bucket.tokens >= cost else {
            buckets[identifier] = bucket
            return false
        }

        bucket.tokens -= cost
        buckets[identifier] = bucket
        performCleanupIfNeeded()
        return true
    }

    public func tryConsumeOrRetryAfter(identifier: String) -> TimeInterval? {
        if tryConsume(identifier: identifier) { return nil }
        let tokensNeeded = Double(config.costPerRequest)
        let currentTokens = buckets[identifier]?.tokens ?? 0
        return max((tokensNeeded - currentTokens) / config.refillRate, 0)
    }

    public func availableTokens(identifier: String) -> Int {
        refillBucket(for: identifier)
        return Int(buckets[identifier]?.tokens ?? Double(config.capacity))
    }

    public func reset(identifier: String) {
        buckets[identifier] = Bucket(capacity: config.capacity)
    }

    public func resetAll() {
        buckets.removeAll()
    }

    public func statistics() -> [String: Int] {
        buckets.mapValues { Int($0.tokens) }
    }

    private func refillBucket(for identifier: String) {
        var bucket = buckets[identifier] ?? Bucket(capacity: config.capacity)
        let now = Date()
        let tokensToAdd = now.timeIntervalSince(bucket.lastRefill) * config.refillRate
        bucket.tokens = min(Double(config.capacity), bucket.tokens + tokensToAdd)
        bucket.lastRefill = now
        buckets[identifier] = bucket
    }

    private func performCleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) >= cleanupInterval else { return }
        let cutoff = now.addingTimeInterval(-cleanupInterval)
        buckets = buckets.filter { $0.value.lastRefill >= cutoff || $0.value.tokens < Double(config.capacity) }
        lastCleanup = now
    }
}

public actor RateLimiterManager {
    private var limiters: [String: RateLimiter] = [:]

    public init() {}

    public func limiter(for purpose: String, config: RateLimiter.Configuration) -> RateLimiter {
        if let existing = limiters[purpose] { return existing }
        let newLimiter = RateLimiter(configuration: config)
        limiters[purpose] = newLimiter
        return newLimiter
    }

    public func resetAll() async {
        for limiter in limiters.values {
            await limiter.resetAll()
        }
    }
}
