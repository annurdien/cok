import XCTest
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
@testable import TunnelCore
@testable import TunnelServer

final class ServerIntegrationTests: XCTestCase, @unchecked Sendable {
    var connectionManager: ConnectionManager!
    var requestTracker: RequestTracker!
    var logger: Logger!

    override func setUp() async throws {
        logger = Logger(label: "test")
        logger.logLevel = .critical
        connectionManager = ConnectionManager(maxConnections: 10, logger: logger)
        requestTracker = RequestTracker(logger: logger)
    }

    func testEndToEndRequestFlow() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let requestID = UUID()
        let httpRequest = HTTPRequestMessage(
            requestID: requestID,
            method: "GET",
            path: "/test",
            headers: [HTTPHeader(name: "host", value: "test.example.com")],
            body: Data(),
            remoteAddress: "127.0.0.1"
        )

        let responseTask = Task {
            try await requestTracker.track(requestID: requestID)
        }

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: httpRequest)

        try await Task.sleep(for: .milliseconds(100))

        let frame = try channel.readOutbound(as: WebSocketFrame.self)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.opcode, .binary)

        var frameData = frame!.unmaskedData
        let decoded = try ProtocolFrame.decode(from: &frameData)
        XCTAssertEqual(decoded.messageType, .httpRequest)

        let httpResponse = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 200,
            headers: [HTTPHeader(name: "content-type", value: "text/plain")],
            body: Data("OK".utf8)
        )

        await requestTracker.complete(requestID: requestID, response: httpResponse)

        let response = try await responseTask.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("OK".utf8))

        try? await channel.close()
    }

    func testConcurrentRequests() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let request1 = HTTPRequestMessage(
            requestID: id1,
            method: "GET",
            path: "/1",
            headers: [],
            body: Data(),
            remoteAddress: "127.0.0.1"
        )

        let request2 = HTTPRequestMessage(
            requestID: id2,
            method: "GET",
            path: "/2",
            headers: [],
            body: Data(),
            remoteAddress: "127.0.0.1"
        )

        let request3 = HTTPRequestMessage(
            requestID: id3,
            method: "GET",
            path: "/3",
            headers: [],
            body: Data(),
            remoteAddress: "127.0.0.1"
        )

        let task1 = Task { try await requestTracker.track(requestID: id1) }
        let task2 = Task { try await requestTracker.track(requestID: id2) }
        let task3 = Task { try await requestTracker.track(requestID: id3) }

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request1)
        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request2)
        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request3)

        try await Task.sleep(for: .milliseconds(100))

        let count = await requestTracker.pendingCount()
        XCTAssertEqual(count, 3)

        let response1 = HTTPResponseMessage(requestID: id1, statusCode: 200, headers: [], body: Data("1".utf8))
        let response2 = HTTPResponseMessage(requestID: id2, statusCode: 200, headers: [], body: Data("2".utf8))
        let response3 = HTTPResponseMessage(requestID: id3, statusCode: 200, headers: [], body: Data("3".utf8))

        await requestTracker.complete(requestID: id1, response: response1)
        await requestTracker.complete(requestID: id2, response: response2)
        await requestTracker.complete(requestID: id3, response: response3)

        let result1 = try await task1.value
        let result2 = try await task2.value
        let result3 = try await task3.value

        XCTAssertEqual(result1.body, Data("1".utf8))
        XCTAssertEqual(result2.body, Data("2".utf8))
        XCTAssertEqual(result3.body, Data("3".utf8))

        try? await channel.close()
    }

    func testTunnelDisconnectCleansUpRequests() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let requestID = UUID()
        let request = HTTPRequestMessage(
            requestID: requestID,
            method: "GET",
            path: "/test",
            headers: [],
            body: Data(),
            remoteAddress: "127.0.0.1"
        )

        let task = Task {
            try await requestTracker.track(requestID: requestID)
        }

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request)

        try await Task.sleep(for: .milliseconds(100))

        await connectionManager.unregisterTunnel(id: tunnel.id)

        let count = await connectionManager.connectionCount()
        XCTAssertEqual(count, 0)

        task.cancel()
        try? await channel.close()
    }

    func testProtocolFrameEncoding() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let requestID = UUID()
        let request = HTTPRequestMessage(
            requestID: requestID,
            method: "POST",
            path: "/api/data",
            headers: [
                HTTPHeader(name: "content-type", value: "application/json"),
                HTTPHeader(name: "authorization", value: "Bearer token123")
            ],
            body: Data("{\"test\":true}".utf8),
            remoteAddress: "192.168.1.100"
        )

        try await connectionManager.sendRequest(tunnelID: tunnel.id, request: request)

        let frame = try channel.readOutbound(as: WebSocketFrame.self)
        XCTAssertNotNil(frame)

        var frameData = frame!.unmaskedData
        let decoded = try ProtocolFrame.decode(from: &frameData)

        XCTAssertEqual(decoded.version, .current)
        XCTAssertEqual(decoded.messageType, .httpRequest)
        XCTAssertGreaterThan(decoded.payload.readableBytes, 0)

        var payloadBuffer = decoded.payload
        let payloadBytes = payloadBuffer.readBytes(length: payloadBuffer.readableBytes)!
        let payloadData = Data(payloadBytes)
        let decodedRequest = try JSONDecoder().decode(HTTPRequestMessage.self, from: payloadData)
        XCTAssertEqual(decodedRequest.requestID, requestID)
        XCTAssertEqual(decodedRequest.method, "POST")
        XCTAssertEqual(decodedRequest.path, "/api/data")
        XCTAssertEqual(decodedRequest.remoteAddress, "192.168.1.100")

        try? await channel.close()
    }

    func testPingMessage() async throws {
        let channel = EmbeddedChannel()
        let tunnel = try await connectionManager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        XCTAssertEqual(tunnel.subdomain, "test")
        XCTAssertEqual(tunnel.apiKey, "key123")

        let retrieved = await connectionManager.getTunnel(forSubdomain: "test")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, tunnel.id)

        try? await channel.close()
    }
}
