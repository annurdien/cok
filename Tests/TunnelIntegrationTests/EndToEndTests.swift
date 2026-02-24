import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import TunnelCore
@testable import TunnelServer

final class EndToEndTests: XCTestCase, @unchecked Sendable {
    var logger: Logger!
    var connectionManager: ConnectionManager!
    var requestTracker: RequestTracker!
    var authService: AuthService!
    var healthChecker: HealthChecker!

    override func setUp() async throws {
        logger = Logger(label: "test.e2e")
        logger.logLevel = .critical
        connectionManager = ConnectionManager(maxConnections: 100, logger: logger)
        requestTracker = RequestTracker(timeout: 5.0, logger: logger)
        authService = AuthService(secret: "test-secret-key-minimum-32-bytes!")
        healthChecker = HealthChecker(version: "0.1.0-test")
    }

    func testFullTunnelLifecycle() async throws {
        let channel = EmbeddedChannel()

        let apiKey = try await authService.createAPIKey(for: "myapp")
        let validated = await authService.validateAPIKey(apiKey.key, subdomain: "myapp")
        XCTAssertNotNil(validated)

        _ = try SubdomainValidator.validate("myapp")

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
                HTTPHeader(name: "host", value: "test.example.com"),
            ],
            body: ByteBuffer(string: "{\"key\":\"value\"}"),
            remoteAddress: "192.168.1.1"
        )

        async let responseResult = requestTracker.track(requestID: requestID)
        await Task.yield()

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request)

        let frame = try channel.readOutbound(as: ProtocolFrame.self)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.messageType, .httpRequest)

        let codec = BinaryMessageCodec()
        let decodedRequest = try codec.decode(HTTPRequestMessage.self, from: frame!.payload)
        XCTAssertEqual(decodedRequest.method, "POST")
        XCTAssertEqual(decodedRequest.path, "/api/data")

        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 201,
            headers: [HTTPHeader(name: "content-type", value: "application/json")],
            body: ByteBuffer(string: "{\"id\":1}")
        )

        await requestTracker.complete(requestID: requestID, response: response)

        let result = try await responseResult
        XCTAssertEqual(result.statusCode, 201)

        try? await channel.close()
    }

    func testRateLimitingIntegration() async throws {
        let config = RateLimiter.Configuration(capacity: 5, refillRate: 5.0)
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
        let codec = BinaryMessageCodec()

        let original = HTTPRequestMessage(
            requestID: UUID(),
            method: "PUT",
            path: "/resource/123",
            headers: [
                HTTPHeader(name: "authorization", value: "Bearer token"),
                HTTPHeader(name: "content-type", value: "application/json"),
            ],
            body: ByteBuffer(string: "{\"update\":true}"),
            remoteAddress: "172.16.0.1"
        )

        let payload = try codec.encode(original)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .httpRequest,
            flags: [.compressed],
            payload: payload
        )

        let encoded = frame.encode()

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

    func testErrorPropagation() async throws {
        let nonExistentID = UUID()

        do {
            let request = HTTPRequestMessage(
                requestID: UUID(),
                method: "GET",
                path: "/",
                headers: [],
                body: ByteBuffer(),
                remoteAddress: "localhost"
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
