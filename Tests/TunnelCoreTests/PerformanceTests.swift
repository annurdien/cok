import XCTest
import NIOCore
import NIOPosix
@testable import TunnelCore

final class BufferPoolTests: XCTestCase {

    func testAcquireReturnsBuffer() {
        let pool = BufferPool()
        let buffer = pool.acquire()
        XCTAssertGreaterThanOrEqual(buffer.capacity, 0)
    }

    func testAcquireWithCapacity() {
        let pool = BufferPool()
        let buffer = pool.acquire(minimumCapacity: 8192)
        XCTAssertGreaterThanOrEqual(buffer.capacity, 8192)
    }

    func testReleaseAndReuse() {
        let pool = BufferPool()
        var buffer = pool.acquire(minimumCapacity: 4096)
        buffer.writeString("test data")

        pool.release(buffer)
        XCTAssertEqual(pool.pooledCount, 1)

        let reused = pool.acquire(minimumCapacity: 1024)
        XCTAssertEqual(reused.readableBytes, 0)
        XCTAssertEqual(pool.pooledCount, 0)
    }

    func testPoolLimit() {
        let pool = BufferPool(maxPoolSize: 2)

        let b1 = pool.acquire()
        let b2 = pool.acquire()
        let b3 = pool.acquire()

        pool.release(b1)
        pool.release(b2)
        pool.release(b3)

        XCTAssertEqual(pool.pooledCount, 2)
    }

    func testDrain() {
        let pool = BufferPool()
        let b1 = pool.acquire()
        let b2 = pool.acquire()
        pool.release(b1)
        pool.release(b2)

        XCTAssertEqual(pool.pooledCount, 2)
        pool.drain()
        XCTAssertEqual(pool.pooledCount, 0)
    }
}

final class BufferPoolActorTests: XCTestCase {

    func testActorAcquireReturnsBuffer() async {
        let pool = BufferPoolActor()
        let buffer = await pool.acquire()
        XCTAssertGreaterThanOrEqual(buffer.capacity, 0)
    }

    func testActorReleaseAndReuse() async {
        let pool = BufferPoolActor()
        var buffer = await pool.acquire(minimumCapacity: 4096)
        buffer.writeString("test")

        await pool.release(buffer)
        let pooledCount = await pool.pooledCount
        XCTAssertEqual(pooledCount, 1)

        let reused = await pool.acquire()
        XCTAssertEqual(reused.readableBytes, 0)
    }
}

final class ConnectionPoolTests: XCTestCase {
    var eventLoopGroup: MultiThreadedEventLoopGroup!

    override func setUp() {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    func testPoolExhaustedError() async {
        let config = ConnectionPool.Configuration(maxConnections: 0)
        let pool = ConnectionPool(configuration: config, eventLoopGroup: eventLoopGroup)

        do {
            _ = try await pool.acquire(host: "localhost", port: 8080)
            XCTFail("Should throw poolExhausted")
        } catch ConnectionPoolError.poolExhausted {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStatistics() async {
        let pool = ConnectionPool(configuration: .init(), eventLoopGroup: eventLoopGroup)
        let stats = await pool.statistics
        XCTAssertEqual(stats.active, 0)
        XCTAssertEqual(stats.pooled, 0)
    }
}

final class BackpressureControllerTests: XCTestCase {

    func testInitialStateAccepting() async {
        let controller = BackpressureController()
        let state = await controller.currentState()
        XCTAssertEqual(state, .accepting)
    }

    func testRequestPermissionAllowed() async {
        let controller = BackpressureController()
        let result = await controller.requestPermission()
        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.delay)
    }

    func testTransitionToThrottling() async {
        let config = BackpressureController.Configuration(lowWatermark: 2, highWatermark: 5, criticalWatermark: 10)
        let controller = BackpressureController(configuration: config)

        for _ in 0..<6 {
            _ = await controller.requestPermission()
        }

        let state = await controller.currentState()
        XCTAssertEqual(state, .throttling)
    }

    func testTransitionToRejecting() async {
        let config = BackpressureController.Configuration(lowWatermark: 2, highWatermark: 5, criticalWatermark: 10)
        let controller = BackpressureController(configuration: config)

        for _ in 0..<11 {
            _ = await controller.requestPermission()
        }

        let state = await controller.currentState()
        XCTAssertEqual(state, .rejecting)

        let result = await controller.requestPermission()
        XCTAssertFalse(result.allowed)
    }

    func testCompleteReducesPending() async {
        let controller = BackpressureController()
        _ = await controller.requestPermission()
        _ = await controller.requestPermission()

        var pending = await controller.pendingCount()
        XCTAssertEqual(pending, 2)

        await controller.complete()
        pending = await controller.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testUtilization() async {
        let config = BackpressureController.Configuration(criticalWatermark: 100)
        let controller = BackpressureController(configuration: config)

        for _ in 0..<50 {
            _ = await controller.requestPermission()
        }

        let util = await controller.utilization()
        XCTAssertEqual(util, 0.5, accuracy: 0.01)
    }
}

final class MemoryPressureMonitorTests: XCTestCase {

    func testInitialLevelNormal() async {
        let monitor = MemoryPressureMonitor()
        let level = await monitor.currentLevel()
        XCTAssertEqual(level, .normal)
    }

    func testWarningLevel() async {
        let monitor = MemoryPressureMonitor(warningThresholdMB: 1, criticalThresholdMB: 2)
        await monitor.recordAllocation(1024 * 1024 + 1)

        let level = await monitor.currentLevel()
        XCTAssertEqual(level, .warning)
    }

    func testCriticalLevel() async {
        let monitor = MemoryPressureMonitor(warningThresholdMB: 1, criticalThresholdMB: 2)
        await monitor.recordAllocation(2 * 1024 * 1024 + 1)

        let level = await monitor.currentLevel()
        XCTAssertEqual(level, .critical)

        let shouldShed = await monitor.shouldShedLoad()
        XCTAssertTrue(shouldShed)
    }

    func testDeallocationReducesUsage() async {
        let monitor = MemoryPressureMonitor(warningThresholdMB: 1, criticalThresholdMB: 2)
        await monitor.recordAllocation(2 * 1024 * 1024)
        await monitor.recordDeallocation(1024 * 1024)

        let usage = await monitor.usage()
        XCTAssertEqual(usage, 1024 * 1024)
    }
}
