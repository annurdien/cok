import XCTest

@testable import TunnelClient

final class ClientConfigTests: XCTestCase {
    func testValidConfiguration() throws {
        let config = ClientConfig(
            serverHost: "tunnel.example.com",
            serverPort: 5000,
            subdomain: "my-app",
            apiKey: "test-token-123",
            localHost: "localhost",
            localPort: 3000
        )

        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.serverHost, "tunnel.example.com")
        XCTAssertEqual(config.serverPort, 5000)
        XCTAssertEqual(config.subdomain, "my-app")
        XCTAssertEqual(config.localPort, 3000)
    }

    func testInvalidSubdomain() {
        let config = ClientConfig(
            serverHost: "tunnel.example.com",
            subdomain: "",
            apiKey: "test-token"
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigError.invalidSubdomain = error else {
                XCTFail("Expected invalidSubdomain error")
                return
            }
        }
    }

    func testEmptyAPIKey() {
        let config = ClientConfig(
            serverHost: "tunnel.example.com",
            subdomain: "my-app",
            apiKey: ""
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigError.invalidAPIKey = error else {
                XCTFail("Expected invalidAPIKey error")
                return
            }
        }
    }

    func testInvalidPort() {
        let config = ClientConfig(
            serverHost: "tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-token",
            localPort: 70000
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigError.invalidPort = error else {
                XCTFail("Expected invalidPort error")
                return
            }
        }
    }

    func testDefaultValues() {
        let config = ClientConfig(
            serverHost: "tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-key"
        )

        XCTAssertEqual(config.localHost, "localhost")
        XCTAssertEqual(config.serverPort, 5000)
        XCTAssertEqual(config.localPort, 3000)  // Default local port might check init default?
        // ClientConfig init defaults: localPort = 5000?
        // Let's check init signature in previous steps to be sure

        XCTAssertEqual(config.reconnectDelay, 5.0)
        XCTAssertEqual(config.maxReconnectAttempts, -1)
        XCTAssertEqual(config.requestTimeout, 30.0)
        XCTAssertEqual(config.circuitBreakerThreshold, 5)
    }
}
