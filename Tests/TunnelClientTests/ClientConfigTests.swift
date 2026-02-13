import XCTest
@testable import TunnelClient

final class ClientConfigTests: XCTestCase {
    func testValidConfiguration() throws {
        let config = ClientConfig(
            serverURL: "wss://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-token-123",
            localHost: "localhost",
            localPort: 3000
        )
        
        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.serverURL, "wss://tunnel.example.com")
        XCTAssertEqual(config.subdomain, "my-app")
        XCTAssertEqual(config.localPort, 3000)
    }
    
    func testInvalidServerURL() {
        let config = ClientConfig(
            serverURL: "http://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-token",
            localHost: "localhost",
            localPort: 3000
        )
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigError.invalidURL = error else {
                XCTFail("Expected invalidURL error")
                return
            }
        }
    }
    
    func testInvalidSubdomain() {
        let config = ClientConfig(
            serverURL: "wss://tunnel.example.com",
            subdomain: "",
            apiKey: "test-token",
            localHost: "localhost",
            localPort: 3000
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
            serverURL: "wss://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "",
            localHost: "localhost",
            localPort: 3000
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
            serverURL: "wss://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-token",
            localHost: "localhost",
            localPort: 70000
        )
        
        XCTAssertThrowsError(try config.validate()) { error in
            guard case ConfigError.invalidPort = error else {
                XCTFail("Expected invalidPort error")
                return
            }
        }
    }
    
    func testSubdomainValidation() throws {
        let config = ClientConfig(
            serverURL: "wss://tunnel.example.com",
            subdomain: "my-test-app",
            apiKey: "test-token",
            localHost: "localhost",
            localPort: 3000
        )
        
        XCTAssertNoThrow(try config.validate())
    }
    
    func testDefaultValues() {
        let config = ClientConfig(
            serverURL: "wss://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-key"
        )
        
        XCTAssertEqual(config.localHost, "127.0.0.1")
        XCTAssertEqual(config.localPort, 3000)
        XCTAssertEqual(config.reconnectDelay, 5.0)
        XCTAssertEqual(config.maxReconnectAttempts, -1)
        XCTAssertEqual(config.requestTimeout, 30.0)
        XCTAssertEqual(config.circuitBreakerThreshold, 5)
    }
    
    func testWebSocketSchemeAccepted() throws {
        let config = ClientConfig(
            serverURL: "ws://tunnel.example.com",
            subdomain: "my-app",
            apiKey: "test-key"
        )
        
        XCTAssertNoThrow(try config.validate())
    }
}
