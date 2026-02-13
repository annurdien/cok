import Foundation

/// Token bucket rate limiter for controlling request rates
public actor RateLimiter {
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Maximum number of tokens in the bucket
        public let capacity: Int
        
        /// Rate at which tokens are refilled (tokens per second)
        public let refillRate: Double
        
        /// Number of tokens consumed per request
        public let costPerRequest: Int
        
        public init(capacity: Int, refillRate: Double, costPerRequest: Int = 1) {
            self.capacity = capacity
            self.refillRate = refillRate
            self.costPerRequest = costPerRequest
        }
        
        /// Configuration for API requests (60 requests per minute)
        public static let api = Configuration(capacity: 60, refillRate: 1.0)
        
        /// Configuration for connection attempts (10 per minute)
        public static let connection = Configuration(capacity: 10, refillRate: 0.167)
        
        /// Configuration for HTTP requests (120 requests per minute)
        public static let http = Configuration(capacity: 120, refillRate: 2.0)
        
        /// Configuration for WebSocket messages (300 per minute)
        public static let websocket = Configuration(capacity: 300, refillRate: 5.0)
    }
    
    // MARK: - Bucket State
    
    private struct Bucket: Sendable {
        var tokens: Double
        var lastRefill: Date
        
        init(capacity: Int) {
            self.tokens = Double(capacity)
            self.lastRefill = Date()
        }
    }
    
    // MARK: - Properties
    
    private let config: Configuration
    private var buckets: [String: Bucket] = [:]
    private let cleanupInterval: TimeInterval = 300  // 5 minutes
    private var lastCleanup: Date = Date()
    
    // MARK: - Initialization
    
    public init(configuration: Configuration) {
        self.config = configuration
    }
    
    // MARK: - Public Methods
    
    /// Attempts to consume tokens from the bucket
    /// - Parameter identifier: Unique identifier for the rate limit scope (e.g., IP address, API key)
    /// - Returns: true if tokens were consumed, false if rate limit exceeded
    public func tryConsume(identifier: String) -> Bool {
        refillBucket(for: identifier)
        
        var bucket = buckets[identifier] ?? Bucket(capacity: config.capacity)
        
        let cost = Double(config.costPerRequest)
        
        guard bucket.tokens >= cost else {
            // Not enough tokens
            buckets[identifier] = bucket
            return false
        }
        
        bucket.tokens -= cost
        buckets[identifier] = bucket
        
        performCleanupIfNeeded()
        return true
    }
    
    /// Attempts to consume tokens, returning time until next available token
    /// - Parameter identifier: Unique identifier for the rate limit scope
    /// - Returns: nil if consumed successfully, otherwise TimeInterval until next token
    public func tryConsumeOrRetryAfter(identifier: String) -> TimeInterval? {
        if tryConsume(identifier: identifier) {
            return nil
        }
        
        // Calculate retry-after time
        let tokensNeeded = Double(config.costPerRequest)
        let currentTokens = buckets[identifier]?.tokens ?? 0
        let tokensToWait = tokensNeeded - currentTokens
        let waitTime = tokensToWait / config.refillRate
        
        return max(waitTime, 0)
    }
    
    /// Gets the current number of tokens available
    /// - Parameter identifier: Unique identifier for the rate limit scope
    /// - Returns: Number of tokens currently available
    public func availableTokens(identifier: String) -> Int {
        refillBucket(for: identifier)
        let bucket = buckets[identifier] ?? Bucket(capacity: config.capacity)
        return Int(bucket.tokens)
    }
    
    /// Resets the rate limit for an identifier
    /// - Parameter identifier: Unique identifier to reset
    public func reset(identifier: String) {
        buckets[identifier] = Bucket(capacity: config.capacity)
    }
    
    /// Clears all rate limit data
    public func resetAll() {
        buckets.removeAll()
    }
    
    /// Gets statistics about current rate limiting
    /// - Returns: Dictionary of identifier to available tokens
    public func statistics() -> [String: Int] {
        var stats: [String: Int] = [:]
        for (identifier, bucket) in buckets {
            stats[identifier] = Int(bucket.tokens)
        }
        return stats
    }
    
    // MARK: - Private Methods
    
    private func refillBucket(for identifier: String) {
        var bucket = buckets[identifier] ?? Bucket(capacity: config.capacity)
        
        let now = Date()
        let timePassed = now.timeIntervalSince(bucket.lastRefill)
        
        // Calculate tokens to add based on time passed
        let tokensToAdd = timePassed * config.refillRate
        bucket.tokens = min(Double(config.capacity), bucket.tokens + tokensToAdd)
        bucket.lastRefill = now
        
        buckets[identifier] = bucket
    }
    
    private func performCleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) >= cleanupInterval else {
            return
        }
        
        // Remove buckets that are at capacity and haven't been used recently
        let cutoffTime = now.addingTimeInterval(-cleanupInterval)
        buckets = buckets.filter { _, bucket in
            bucket.lastRefill >= cutoffTime || bucket.tokens < Double(config.capacity)
        }
        
        lastCleanup = now
    }
}

// MARK: - Rate Limiter Manager

/// Manages multiple rate limiters for different purposes
public actor RateLimiterManager {
    private var limiters: [String: RateLimiter] = [:]
    
    public init() {}
    
    /// Gets or creates a rate limiter for a specific purpose
    /// - Parameters:
    ///   - purpose: The purpose/name of the rate limiter
    ///   - config: Configuration for the rate limiter
    /// - Returns: Rate limiter instance
    public func limiter(for purpose: String, config: RateLimiter.Configuration) -> RateLimiter {
        if let existing = limiters[purpose] {
            return existing
        }
        
        let newLimiter = RateLimiter(configuration: config)
        limiters[purpose] = newLimiter
        return newLimiter
    }
    
    /// Resets all rate limiters
    public func resetAll() async {
        for limiter in limiters.values {
            await limiter.resetAll()
        }
    }
}
