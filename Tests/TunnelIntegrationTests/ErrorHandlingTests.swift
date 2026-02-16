import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import TunnelCore
@testable import TunnelServer

final class ErrorHandlingTests: XCTestCase, @unchecked Sendable {
    var connectionManager: ConnectionManager!
    var requestTracker: RequestTracker!
    var logger: Logger!

    override func setUp() async throws {
        logger = Logger(label: "test")
        logger.logLevel = .critical
        connectionManager = ConnectionManager(maxConnections: 10, logger: logger)
        requestTracker = RequestTracker(logger: logger)
    }

    func testRequestTimeout() async throws {
        let shortTracker = RequestTracker(timeout: 0.1, logger: logger)
        let requestID = UUID()

        do {
            _ = try await shortTracker.track(requestID: requestID)
            XCTFail("Should have timed out")
        } catch {
            XCTAssertTrue(error is TunnelError)
        }
    }

    func testTunnelNotFound() async throws {
        let nonExistentID = UUID()
        let request = HTTPRequestMessage(
            requestID: UUID(),
            method: "GET",
            path: "/",
            headers: [],
            body: ByteBuffer(),
            remoteAddress: "localhost"
        )

        do {
            try await connectionManager.sendRequest(tunnelID: nonExistentID, request: request)
            XCTFail("Should have thrown tunnelNotFound error")
        } catch {
            XCTAssertTrue(error is TunnelError)
        }
    }

    func testInvalidAPIKey() async throws {
        let authService = AuthService(secret: "test-secret")
        let result = await authService.validateAPIKey("invalid-key")
        XCTAssertNil(result)
    }

    func testMaxConnectionsLimit() async throws {
        let smallManager = ConnectionManager(maxConnections: 2, logger: logger)

        let ch1 = EmbeddedChannel()
        let ch2 = EmbeddedChannel()
        let ch3 = EmbeddedChannel()

        _ = try await smallManager.registerTunnel(subdomain: "test1", apiKey: "key1", channel: ch1)
        _ = try await smallManager.registerTunnel(subdomain: "test2", apiKey: "key2", channel: ch2)

        do {
            _ = try await smallManager.registerTunnel(
                subdomain: "test3", apiKey: "key3", channel: ch3)
            XCTFail("Should have rejected connection")
        } catch {
            XCTAssertTrue(error is ServerError)
        }

        try? await ch1.close()
        try? await ch2.close()
        try? await ch3.close()
    }

    func testDuplicateSubdomain() async throws {
        let ch1 = EmbeddedChannel()
        let ch2 = EmbeddedChannel()

        _ = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key1",
            channel: ch1
        )

        do {
            _ = try await connectionManager.registerTunnel(
                subdomain: "test",
                apiKey: "key2",
                channel: ch2
            )
            XCTFail("Should have rejected duplicate subdomain")
        } catch {
            XCTAssertTrue(error is ServerError)
        }

        try? await ch1.close()
        try? await ch2.close()
    }

    func testCancelledRequest() async throws {
        let requestID = UUID()

        let task = Task {
            try await requestTracker.track(requestID: requestID)
        }

        try await Task.sleep(for: .milliseconds(100))

        let error = TunnelError.client(.timeout, context: ErrorContext(component: "test"))
        await requestTracker.fail(requestID: requestID, error: error)

        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch {
            XCTAssertTrue(error is TunnelError || error is CancellationError)
        }
    }

    func testInvalidProtocolFrame() async throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(ProtocolFrameDecoder()))
        _ = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        var invalidBuffer = ByteBufferAllocator().buffer(capacity: 10)
        // Invalid version (0xFF), valid rest (type, flags, len=0) to ensure it tries validity check
        invalidBuffer.writeInteger(UInt8(0xFF))  // Version
        invalidBuffer.writeInteger(UInt8(MessageType.connectRequest.rawValue))  // Type
        invalidBuffer.writeInteger(UInt8(0))  // Flags
        invalidBuffer.writeInteger(UInt32(0))  // Payload Length
        // CRC (4 bytes, just zeros or something)
        invalidBuffer.writeInteger(UInt32(0))

        do {
            try channel.writeInbound(invalidBuffer)
            XCTFail("Should have thrown error")
        } catch {
            // It should throw ProtocolError.unsupportedVersion
            XCTAssertTrue(error is ProtocolError || error is DecodingError)
        }

        try? await channel.close()
    }

    func testResponseAfterTimeout() async throws {
        let shortTracker = RequestTracker(timeout: 0.1, logger: logger)
        let requestID = UUID()

        do {
            _ = try await shortTracker.track(requestID: requestID)
            XCTFail("Should have timed out")
        } catch {
            XCTAssertTrue(error is TunnelError)
        }

        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 200,
            headers: [],
            body: ByteBuffer()
        )

        await shortTracker.complete(requestID: requestID, response: response)

        let count = await shortTracker.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testUnregisterNonExistentTunnel() async throws {
        let randomID = UUID()
        await connectionManager.unregisterTunnel(id: randomID)

        let count = await connectionManager.connectionCount()
        XCTAssertEqual(count, 0)
    }

    func testEmptySubdomain() async throws {
        let channel = EmbeddedChannel()

        do {
            _ = try await connectionManager.registerTunnel(
                subdomain: "",
                apiKey: "key123",
                channel: channel
            )
            XCTFail("Should have rejected empty subdomain")
        } catch {
            XCTAssertTrue(error is ServerError)
        }

        try? await channel.close()
    }

    func testLargeRequestBody() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        var largeBuffer = ByteBufferAllocator().buffer(capacity: 1024 * 1024)
        largeBuffer.writeBytes(Array(repeating: UInt8(65), count: 1024 * 1024))

        let request = HTTPRequestMessage(
            requestID: UUID(),
            method: "POST",
            path: "/upload",
            headers: [HTTPHeader(name: "content-type", value: "application/octet-stream")],
            body: largeBuffer,
            remoteAddress: "localhost"
        )

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request)

        let frame = try channel.readOutbound(as: ProtocolFrame.self)
        XCTAssertNotNil(frame)

        XCTAssertEqual(frame?.messageType, .httpRequest)

        let codec = BinaryMessageCodec()
        let decodedRequest = try codec.decode(HTTPRequestMessage.self, from: frame!.payload)
        XCTAssertEqual(decodedRequest.body.readableBytes, 1024 * 1024)

        try? await channel.close()
    }
}
