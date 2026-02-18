import XCTest
@testable import TunnelClient

final class CircuitBreakerTests: XCTestCase {
    func testInitiallyClosedState() async {
        let breaker = CircuitBreaker(
            threshold: 3,
            timeout: 1.0
        )

        let result = await breaker.tryAcquire()
        XCTAssertTrue(result)
    }

    func testOpensAfterFailureThreshold() async {
        let breaker = CircuitBreaker(
            threshold: 3,
            timeout: 1.0
        )

        await breaker.recordFailure()
        var canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)

        await breaker.recordFailure()
        canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)

        await breaker.recordFailure()
        canAttempt = await breaker.tryAcquire()
        XCTAssertFalse(canAttempt)
    }

    func testResetsFailureCountOnSuccess() async {
        let breaker = CircuitBreaker(
            threshold: 3,
            timeout: 1.0
        )

        await breaker.recordFailure()
        await breaker.recordFailure()

        await breaker.recordSuccess()

        await breaker.recordFailure()
        var canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)

        await breaker.recordFailure()
        canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)
    }

    func testTransitionsToHalfOpenAfterTimeout() async {
        let breaker = CircuitBreaker(
            threshold: 2,
            timeout: 0.1
        )

        await breaker.recordFailure()
        await breaker.recordFailure()

        var canAttempt = await breaker.tryAcquire()
        XCTAssertFalse(canAttempt)

        try? await Task.sleep(for: .seconds(0.2))

        canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)
    }

    func testHalfOpenTransitionsToClosedOnSuccess() async {
        let breaker = CircuitBreaker(
            threshold: 2,
            timeout: 0.1
        )

        await breaker.recordFailure()
        await breaker.recordFailure()

        try? await Task.sleep(for: .seconds(0.2))

        var canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)

        await breaker.recordSuccess()
        canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)
    }

    func testHalfOpenTransitionsToOpenOnFailure() async {
        let breaker = CircuitBreaker(
            threshold: 2,
            timeout: 0.1
        )

        await breaker.recordFailure()
        await breaker.recordFailure()

        try? await Task.sleep(for: .seconds(0.2))

        var canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)

        await breaker.recordFailure()

        canAttempt = await breaker.tryAcquire()
        XCTAssertFalse(canAttempt)
    }

    func testConcurrentAccess() async {
        let breaker = CircuitBreaker(
            threshold: 10,
            timeout: 1.0
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await breaker.recordFailure()
                }
            }

            for _ in 0..<5 {
                group.addTask {
                    await breaker.recordSuccess()
                }
            }

            for _ in 0..<10 {
                group.addTask {
                    _ = await breaker.tryAcquire()
                }
            }
        }

        let canAttempt = await breaker.tryAcquire()
        XCTAssertTrue(canAttempt)
    }
}
