import Logging
import NIOCore
import NIOEmbedded
import XCTest

@testable import TunnelCore
@testable import TunnelServer

final class ConnectionManagerTests: XCTestCase {
    var manager: ConnectionManager!
    var logger: Logger!
    var channel: EmbeddedChannel!

    override func setUp() async throws {
        logger = Logger(label: "test")
        logger.logLevel = .critical
        manager = ConnectionManager(maxConnections: 10, logger: logger)
        channel = EmbeddedChannel()
    }

    override func tearDown() async throws {
        try? await channel?.close()
    }

    func testRegisterTunnel() async throws {
        let tunnel = try await manager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        XCTAssertEqual(tunnel.subdomain, "test")
        XCTAssertEqual(tunnel.apiKey, "key123")

        let count = await manager.connectionCount()
        XCTAssertEqual(count, 1)
    }

    func testGetTunnelBySubdomain() async throws {
        let registered = try await manager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let retrieved = await manager.getTunnel(forSubdomain: "test")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, registered.id)
        XCTAssertEqual(retrieved?.subdomain, "test")
    }

    func testDuplicateSubdomainRejected() async throws {
        _ = try await manager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let channel2 = EmbeddedChannel()

        do {
            _ = try await manager.registerTunnel(
                subdomain: "test",
                apiKey: "key456",
                channel: channel2
            )
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is ServerError)
        }

        try? await channel2.close()
    }

    func testMaxConnectionsEnforced() async throws {
        let smallManager = ConnectionManager(maxConnections: 2, logger: logger)

        let ch1 = EmbeddedChannel()
        let ch2 = EmbeddedChannel()
        let ch3 = EmbeddedChannel()

        _ = try await smallManager.registerTunnel(subdomain: "test1", apiKey: "key1", channel: ch1)
        _ = try await smallManager.registerTunnel(subdomain: "test2", apiKey: "key2", channel: ch2)

        do {
            _ = try await smallManager.registerTunnel(
                subdomain: "test3", apiKey: "key3", channel: ch3)
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is ServerError)
        }

        try? await ch1.close()
        try? await ch2.close()
        try? await ch3.close()
    }

    func testUnregisterTunnel() async throws {
        let tunnel = try await manager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        var count = await manager.connectionCount()
        XCTAssertEqual(count, 1)

        await manager.unregisterTunnel(id: tunnel.id)
        count = await manager.connectionCount()
        XCTAssertEqual(count, 0)

        let retrieved = await manager.getTunnel(forSubdomain: "test")
        XCTAssertNil(retrieved)
    }

    func testSendRequestToTunnel() async throws {
        let tunnel = try await manager.registerTunnel(
            subdomain: "test",
            apiKey: "key123",
            channel: channel
        )

        let request = HTTPRequestMessage(
            requestID: UUID(),
            method: "GET",
            path: "/test",
            headers: [],
            body: ByteBuffer(),
            remoteAddress: "localhost"
        )

        try await manager.sendRequest(tunnelID: tunnel.id, request: request)

        let frame = try channel.readOutbound(as: ProtocolFrame.self)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.messageType, .httpRequest)
    }
}
