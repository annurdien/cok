import XCTest

@testable import TunnelServer

final class SecurityTests: XCTestCase {
    var authService: AuthService!

    override func setUp() async throws {
        authService = AuthService(secret: "test-secret-key")
    }

    // MARK: - API Key Tests

    func testCreateAPIKey() async throws {
        let apiKey = try await authService.createAPIKey(for: "test-subdomain")

        XCTAssertEqual(apiKey.subdomain, "test-subdomain")
        XCTAssertFalse(apiKey.key.isEmpty)
        XCTAssertEqual(apiKey.key.count, 64)  // SHA256 hex = 64 chars
    }

    func testValidateAPIKey() async throws {
        let apiKey = try await authService.createAPIKey(for: "test")

        let validated = await authService.validateAPIKey(apiKey.key, subdomain: "test")
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.subdomain, "test")
    }

    func testValidateInvalidAPIKey() async {
        let validated = await authService.validateAPIKey("deadbeef", subdomain: "invalid-subdomain")
        XCTAssertNil(validated)
    }

    func testValidateStaticHMACKey() async {
        let authForStaticTest = AuthService(secret: "test-secret-key")
        let validated = await authForStaticTest.validateAPIKey(
            "test-static-key-placeholder",
            subdomain: "myapp"
        )
        XCTAssertNil(validated)

        let isValid = await authForStaticTest.verifyStaticKey(
            "test-static-key-placeholder",
            subdomain: "myapp"
        )
        XCTAssertFalse(isValid)
    }

    func testRevokeAPIKey() async throws {
        let apiKey = try await authService.createAPIKey(for: "test")

        var validated = await authService.validateAPIKey(apiKey.key, subdomain: "test")
        XCTAssertNotNil(validated)

        await authService.revokeAPIKey(apiKey.key)

        validated = await authService.validateAPIKey(apiKey.key, subdomain: "test")
        XCTAssertNil(validated)
    }

    func testListKeys() async throws {
        _ = try await authService.createAPIKey(for: "test1")
        _ = try await authService.createAPIKey(for: "test2")

        let keys = await authService.listKeys()
        XCTAssertEqual(keys.count, 2)
    }

    func testAPIKeyExpiration() async throws {
        let apiKey = try await authService.createAPIKey(for: "test", expiresIn: -1)

        XCTAssertTrue(apiKey.isExpired)

        let validated = await authService.validateAPIKey(apiKey.key, subdomain: "test")
        XCTAssertNil(validated, "Expired key should not validate")
    }

    func testCleanupExpiredKeys() async throws {
        _ = try await authService.createAPIKey(for: "test1", expiresIn: -1)
        _ = try await authService.createAPIKey(for: "test2", expiresIn: 3600)

        await authService.cleanupExpiredKeys()

        let keys = await authService.listKeys()
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.subdomain, "test2")
    }
}
