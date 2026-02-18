import XCTest

@testable import TunnelCore

final class RateLimiterTests: XCTestCase {

    func testInitialCapacity() async {
        let limiter = RateLimiter(configuration: .init(capacity: 10, refillRate: 1.0))

        let available = await limiter.availableTokens(identifier: "test")
        XCTAssertEqual(available, 10)
    }

    func testConsumeTokens() async {
        let limiter = RateLimiter(configuration: .init(capacity: 10, refillRate: 1.0))

        let result1 = await limiter.tryConsume(identifier: "test")
        XCTAssertTrue(result1)

        let available = await limiter.availableTokens(identifier: "test")
        XCTAssertEqual(available, 9)
    }

    func testRateLimitExceeded() async {
        let limiter = RateLimiter(configuration: .init(capacity: 3, refillRate: 0.1))

        // Consume all tokens
        let result1 = await limiter.tryConsume(identifier: "test")
        let result2 = await limiter.tryConsume(identifier: "test")
        let result3 = await limiter.tryConsume(identifier: "test")
        XCTAssertTrue(result1)
        XCTAssertTrue(result2)
        XCTAssertTrue(result3)

        // Next attempt should fail
        let result4 = await limiter.tryConsume(identifier: "test")
        XCTAssertFalse(result4)
    }

    func testTokenRefill() async throws {
        let limiter = RateLimiter(configuration: .init(capacity: 10, refillRate: 10.0))  // 10 tokens per second

        // Consume some tokens
        let consumed1 = await limiter.tryConsume(identifier: "test")
        let consumed2 = await limiter.tryConsume(identifier: "test")
        XCTAssertTrue(consumed1)
        XCTAssertTrue(consumed2)

        let availableBefore = await limiter.availableTokens(identifier: "test")
        XCTAssertEqual(availableBefore, 8)

        // Wait for refill (100ms = 1 token at 10 tokens/sec)
        try await Task.sleep(for: .milliseconds(100))

        let availableAfter = await limiter.availableTokens(identifier: "test")
        XCTAssertGreaterThan(availableAfter, availableBefore)
    }

    func testMultipleIdentifiers() async {
        let limiter = RateLimiter(configuration: .init(capacity: 5, refillRate: 1.0))

        // Consume tokens for first identifier
        let consumed1 = await limiter.tryConsume(identifier: "user1")
        let consumed2 = await limiter.tryConsume(identifier: "user1")
        XCTAssertTrue(consumed1)
        XCTAssertTrue(consumed2)

        // Second identifier should have full capacity
        let available2 = await limiter.availableTokens(identifier: "user2")
        XCTAssertEqual(available2, 5)

        // First identifier should have reduced capacity
        let available1 = await limiter.availableTokens(identifier: "user1")
        XCTAssertEqual(available1, 3)
    }

    func testReset() async {
        let limiter = RateLimiter(configuration: .init(capacity: 5, refillRate: 1.0))

        // Consume all tokens
        for _ in 0..<5 {
            _ = await limiter.tryConsume(identifier: "test")
        }

        let tokensBeforeReset = await limiter.availableTokens(identifier: "test")
        XCTAssertEqual(tokensBeforeReset, 0)

        // Reset
        await limiter.reset(identifier: "test")

        let tokensAfterReset = await limiter.availableTokens(identifier: "test")
        XCTAssertEqual(tokensAfterReset, 5)
    }

    func testResetAll() async {
        let limiter = RateLimiter(configuration: .init(capacity: 5, refillRate: 1.0))

        // Consume tokens for multiple identifiers
        _ = await limiter.tryConsume(identifier: "user1")
        _ = await limiter.tryConsume(identifier: "user2")

        await limiter.resetAll()

        let tokensUser1 = await limiter.availableTokens(identifier: "user1")
        let tokensUser2 = await limiter.availableTokens(identifier: "user2")
        XCTAssertEqual(tokensUser1, 5)
        XCTAssertEqual(tokensUser2, 5)
    }

    func testRetryAfter() async {
        let limiter = RateLimiter(configuration: .init(capacity: 1, refillRate: 1.0))

        // Consume the only token
        _ = await limiter.tryConsume(identifier: "test")

        // Try to consume again and get retry-after
        let retryAfter = await limiter.tryConsumeOrRetryAfter(identifier: "test")
        XCTAssertNotNil(retryAfter)
        XCTAssertGreaterThan(retryAfter!, 0)
    }

    func testPresetConfigurationAPI() async {
        let apiLimiter = RateLimiter(configuration: .api)
        let apiTokens = await apiLimiter.availableTokens(identifier: "test")
        XCTAssertEqual(apiTokens, 60)
    }

    func testPresetConfigurationConnection() async {
        let connectionLimiter = RateLimiter(configuration: .connection)
        let connTokens = await connectionLimiter.availableTokens(identifier: "test")
        XCTAssertEqual(connTokens, 10)
    }

    func testPresetConfigurationHTTP() async {
        let httpLimiter = RateLimiter(configuration: .http)
        let httpTokens = await httpLimiter.availableTokens(identifier: "test")
        XCTAssertEqual(httpTokens, 120)
    }

    func testPresetConfigurationWebSocket() async {
        let wsLimiter = RateLimiter(configuration: .websocket)
        let wsTokens = await wsLimiter.availableTokens(identifier: "test")
        XCTAssertEqual(wsTokens, 300)
    }

    func testStatistics() async {
        let limiter = RateLimiter(configuration: .init(capacity: 10, refillRate: 1.0))

        _ = await limiter.tryConsume(identifier: "user1")
        _ = await limiter.tryConsume(identifier: "user2")
        _ = await limiter.tryConsume(identifier: "user2")

        let stats = await limiter.statistics()
        XCTAssertEqual(stats["user1"], 9)
        XCTAssertEqual(stats["user2"], 8)
    }
}
