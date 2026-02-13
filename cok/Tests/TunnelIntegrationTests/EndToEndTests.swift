import XCTest
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
@testable import TunnelCore
@testable import TunnelServer

final class EndToEndTests: XCTestCase, @unchecked Sendable {
    var logger: Logger!
    var connectionManager: ConnectionManager!
    var requestTracker: RequestTracker!
    var authService: AuthService!
    var metrics: MetricsCollector!
    var healthChecker: HealthChecker!

    override func setUp() async throws {
        logger = Logger(label: "test.e2e")
        logger.logLevel = .critical
        connectionManager = ConnectionManager(maxConnections: 100, logger: logger)
        requestTracker = RequestTracker(timeout: 5.0, logger: logger)
        authService = AuthService(secret: "test-secret-key-minimum-32-bytes!")
        metrics = MetricsCollector()
        healthChecker = HealthChecker(version: "1.0.0-test")
    }

    func testFullTunnelLifecycle() async throws {
        let channel = EmbeddedChannel()

        let apiKey = try await authService.createAPIKey(for: "myapp")
        let validated = await authService.validateAPIKey(apiKey.key)
        XCTAssertNotNil(validated)

        try SubdomainValidator.validate("myapp")

        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "myapp",
            apiKey: apiKey.key,
            channel: channel
        )
        XCTAssertEqual(tunnel.subdomain, "myapp")

        let retrieved = await connectionManager.getTunnel(forSubdomain: "myapp")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, tunnel.id)

        await connectionManager.unregisterTunnel(id: tunnel.id)
        let afterUnregister = await connectionManager.getTunnel(forSubdomain: "myapp")
        XCTAssertNil(afterUnregister)

        try? await channel.close()
    }

    func testRequestResponseCycle() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key",
            channel: channel
        )

        let requestID = UUID()
        let request = HTTPRequestMessage(
            requestID: requestID,
            method: "POST",
            path: "/api/data",
            headers: [
                HTTPHeader(name: "content-type", value: "application/json"),
                HTTPHeader(name: "host", value: "test.example.com")
            ],
            body: Data("{\"key\":\"value\"}".utf8),
            remoteAddress: "192.168.1.1"
        )

        let responseTask = Task {
            try await requestTracker.track(requestID: requestID)
        }

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request)

        let frame = try channel.readOutbound(as: WebSocketFrame.self)
        XCTAssertNotNil(frame)

        var frameData = frame!.unmaskedData
        let protocolFrame = try ProtocolFrame.decode(from: &frameData)
        XCTAssertEqual(protocolFrame.messageType, .httpRequest)

        let codec = JSONMessageCodec()
        let decodedRequest = try codec.decode(HTTPRequestMessage.self, from: protocolFrame.payload)
        XCTAssertEqual(decodedRequest.method, "POST")
        XCTAssertEqual(decodedRequest.path, "/api/data")

        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 201,
            headers: [HTTPHeader(name: "content-type", value: "application/json")],
            body: Data("{\"id\":1}".utf8)
        )

        await requestTracker.complete(requestID: requestID, response: response)

        let result = try await responseTask.value
        XCTAssertEqual(result.statusCode, 201)

        try? await channel.close()
    }

    func testRateLimitingIntegration() async throws {
        let config = RateLimiter.Configuration(
            capacity: 5,
            refillRate: 5.0
        )
        let limiter = RateLimiter(configuration: config)

        let clientIP = "10.0.0.1"

        for _ in 0..<5 {
            let allowed = await limiter.tryConsume(identifier: clientIP)
            XCTAssertTrue(allowed)
        }

        let exceeded = await limiter.tryConsume(identifier: clientIP)
        XCTAssertFalse(exceeded)

        let otherClient = await limiter.tryConsume(identifier: "10.0.0.2")
        XCTAssertTrue(otherClient)
    }

    func testSecurityValidationChain() async throws {
        let sanitized = try InputSanitizer.sanitizeString("Hello World")
        XCTAssertEqual(sanitized, "Hello World")

        XCTAssertThrowsError(try InputSanitizer.sanitizeString("'; DROP TABLE users; --"))
        XCTAssertThrowsError(try InputSanitizer.sanitizeString("<script>alert('xss')</script>"))
        XCTAssertThrowsError(try InputSanitizer.sanitizePath("../../../etc/passwd"))

        try RequestSizeValidator.validateBodySize(1024)
        try RequestSizeValidator.validateHeaderCount(50)
    }

    func testMetricsCollection() async throws {
        await metrics.increment("requests.total", labels: ["method": "GET"])
        await metrics.increment("requests.total", labels: ["method": "GET"])
        await metrics.increment("requests.total", labels: ["method": "POST"])

        let allMetrics = await metrics.allMetrics()
        XCTAssertTrue(allMetrics.counters.keys.contains { $0.hasPrefix("requests.total") })

        await metrics.gauge("connections.active", value: 42)
        let afterGauge = await metrics.allMetrics()
        XCTAssertTrue(afterGauge.gauges.keys.contains { $0.hasPrefix("connections.active") })

        await metrics.histogram("request.duration", value: 0.1)
        await metrics.histogram("request.duration", value: 0.2)
        await metrics.histogram("request.duration", value: 0.5)

        let stats = await metrics.histogramStats("request.duration")
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, 3)
    }

    func testHealthCheckSystem() async throws {
        await healthChecker.register(name: "database") {
            .healthy("Connected")
        }

        await healthChecker.register(name: "cache") {
            .degraded("High latency")
        }

        let report = await healthChecker.runChecks()
        XCTAssertEqual(report.status, .degraded)

        let liveness = await healthChecker.liveness()
        XCTAssertEqual(liveness.status, .healthy)

        let readiness = await healthChecker.readiness()
        XCTAssertEqual(readiness.status, .degraded)
    }

    func testProtocolFrameRoundtrip() async throws {
        let codec = JSONMessageCodec()

        let original = HTTPRequestMessage(
            requestID: UUID(),
            method: "PUT",
            path: "/resource/123",
            headers: [
                HTTPHeader(name: "authorization", value: "Bearer token"),
                HTTPHeader(name: "content-type", value: "application/json")
            ],
            body: Data("{\"update\":true}".utf8),
            remoteAddress: "172.16.0.1"
        )

        let payload = try codec.encode(original)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .httpRequest,
            flags: [.compressed],
            payload: payload
        )

        let encoded = try frame.encode()

        var buffer = encoded
        let decoded = try ProtocolFrame.decode(from: &buffer)

        XCTAssertEqual(decoded.version, .current)
        XCTAssertEqual(decoded.messageType, .httpRequest)
        XCTAssertTrue(decoded.flags.contains(.compressed))

        let decodedRequest = try codec.decode(HTTPRequestMessage.self, from: decoded.payload)
        XCTAssertEqual(decodedRequest.method, original.method)
        XCTAssertEqual(decodedRequest.path, original.path)
        XCTAssertEqual(decodedRequest.requestID, original.requestID)
    }

    func testBackpressureUnderLoad() async throws {
        let config = BackpressureController.Configuration(
            lowWatermark: 5,
            highWatermark: 10,
            criticalWatermark: 20
        )
        let controller = BackpressureController(configuration: config)

        for _ in 0..<3 {
            let result = await controller.requestPermission()
            XCTAssertTrue(result.allowed)
        }

        let state1 = await controller.currentState()
        XCTAssertEqual(state1, BackpressureController.State.accepting)

        for _ in 0..<8 {
            _ = await controller.requestPermission()
        }

        for _ in 0..<10 {
            await controller.complete()
        }

        let finalState = await controller.currentState()
        XCTAssertEqual(finalState, BackpressureController.State.accepting)
    }

    func testBufferPoolEfficiency() async throws {
        let pool = BufferPoolActor(maxPoolSize: 10, defaultCapacity: 4096)

        var buffers: [ByteBuffer] = []
        for _ in 0..<5 {
            let buffer = await pool.acquire(minimumCapacity: 1024)
            buffers.append(buffer)
        }

        XCTAssertEqual(buffers.count, 5)

        for buffer in buffers {
            await pool.release(buffer)
        }

        let reused = await pool.acquire(minimumCapacity: 1024)
        XCTAssertGreaterThanOrEqual(reused.capacity, 1024)
    }

    func testGracefulShutdown() async throws {
        let shutdown = GracefulShutdown(logger: logger, timeout: 5)

        let callTracker = CallTracker()

        await shutdown.register {
            await callTracker.markCalled(1)
        }

        await shutdown.register {
            await callTracker.markCalled(2)
        }

        let beforeShutdown = await shutdown.shuttingDown
        XCTAssertFalse(beforeShutdown)

        await shutdown.shutdown(signal: .user(1))

        let called1 = await callTracker.wasCalled(1)
        let called2 = await callTracker.wasCalled(2)
        XCTAssertTrue(called1)
        XCTAssertTrue(called2)
        let afterShutdown = await shutdown.shuttingDown
        XCTAssertTrue(afterShutdown)
    }

    func testRequestTracing() async throws {
        let tracer = RequestTracer()

        let context = await tracer.startSpan(operationName: "http.request")
        await tracer.setTag(spanID: context.spanID, key: "http.method", value: "GET")
        await tracer.setTag(spanID: context.spanID, key: "http.url", value: "/api/users")
        await tracer.log(spanID: context.spanID, message: "Processing request")

        let childContext = await tracer.startSpan(operationName: "db.query", parentSpanID: context.spanID)
        await tracer.setTag(spanID: childContext.spanID, key: "db.statement", value: "SELECT * FROM users")
        await tracer.endSpan(spanID: childContext.spanID)

        await tracer.endSpan(spanID: context.spanID)

        XCTAssertFalse(context.traceID.isEmpty)
        XCTAssertFalse(context.spanID.isEmpty)
    }

    func testMultipleTunnelIsolation() async throws {
        let channel1 = EmbeddedChannel()
        let channel2 = EmbeddedChannel()
        let channel3 = EmbeddedChannel()

        let tunnel1 = try await connectionManager.registerTunnel(
            subdomain: "app1", apiKey: "key1", channel: channel1)
        let tunnel2 = try await connectionManager.registerTunnel(
            subdomain: "app2", apiKey: "key2", channel: channel2)
        let tunnel3 = try await connectionManager.registerTunnel(
            subdomain: "app3", apiKey: "key3", channel: channel3)

        let lookup1 = await connectionManager.getTunnel(forSubdomain: "app1")
        let lookup2 = await connectionManager.getTunnel(forSubdomain: "app2")
        let lookup3 = await connectionManager.getTunnel(forSubdomain: "app3")

        XCTAssertEqual(lookup1?.id, tunnel1.id)
        XCTAssertEqual(lookup2?.id, tunnel2.id)
        XCTAssertEqual(lookup3?.id, tunnel3.id)

        XCTAssertNotEqual(tunnel1.id, tunnel2.id)
        XCTAssertNotEqual(tunnel2.id, tunnel3.id)

        let count = await connectionManager.connectionCount()
        XCTAssertEqual(count, 3)

        await connectionManager.unregisterTunnel(id: tunnel2.id)

        let afterRemoval = await connectionManager.connectionCount()
        XCTAssertEqual(afterRemoval, 2)

        let lookup2After = await connectionManager.getTunnel(forSubdomain: "app2")
        XCTAssertNil(lookup2After)

        try? await channel1.close()
        try? await channel2.close()
        try? await channel3.close()
    }

    func testConcurrentRequestsWithMetrics() async throws {
        let channel = EmbeddedChannel()
        _ = try await connectionManager.registerTunnel(
            subdomain: "concurrent", apiKey: "key", channel: channel)

        let localMetrics = MetricsCollector()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await localMetrics.increment("requests", labels: ["id": "\(i)"])
                    await localMetrics.histogram("latency", value: Double.random(in: 0.01...0.5))
                }
            }
        }

        let allMetrics = await localMetrics.allMetrics()
        XCTAssertFalse(allMetrics.counters.isEmpty)
        XCTAssertFalse(allMetrics.histograms.isEmpty)

        try? await channel.close()
    }

    func testErrorPropagation() async throws {
        let nonExistentID = UUID()

        do {
            let request = HTTPRequestMessage(
                requestID: UUID(),
                method: "GET",
                path: "/",
                headers: [],
                body: Data(),
                remoteAddress: "127.0.0.1"
            )
            try await connectionManager.sendRequest(tunnelID: nonExistentID, request: request)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is TunnelError)
        }

        do {
            let channel = EmbeddedChannel()
            _ = try await connectionManager.registerTunnel(
                subdomain: "taken", apiKey: "key1", channel: channel)
            _ = try await connectionManager.registerTunnel(
                subdomain: "taken", apiKey: "key2", channel: channel)
            XCTFail("Should have thrown for duplicate subdomain")
        } catch {
            XCTAssertTrue(error is ServerError)
        }
    }
}

private actor CallTracker {
    private var calledHandlers: Set<Int> = []

    func markCalled(_ id: Int) { calledHandlers.insert(id) }
    func wasCalled(_ id: Int) -> Bool { calledHandlers.contains(id) }
}
