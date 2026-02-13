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
        XCTAssertEqual(apiKey.key.count, 64) // SHA256 hex = 64 chars
    }

    func testValidateAPIKey() async throws {
        let apiKey = try await authService.createAPIKey(for: "test")

        let validated = await authService.validateAPIKey(apiKey.key)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.subdomain, "test")
    }

    func testValidateInvalidAPIKey() async {
        let validated = await authService.validateAPIKey("invalid-key")
        XCTAssertNil(validated)
    }

    func testRevokeAPIKey() async throws {
        let apiKey = try await authService.createAPIKey(for: "test")

        var validated = await authService.validateAPIKey(apiKey.key)
        XCTAssertNotNil(validated)

        await authService.revokeAPIKey(apiKey.key)

        validated = await authService.validateAPIKey(apiKey.key)
        XCTAssertNil(validated)
    }

    func testListKeys() async throws {
        _ = try await authService.createAPIKey(for: "test1")
        _ = try await authService.createAPIKey(for: "test2")

        let keys = await authService.listKeys()
        XCTAssertEqual(keys.count, 2)
    }

    func testAPIKeyExpiration() async throws {
        let apiKey = try await authService.createAPIKey(for: "test", expiresIn: -1) // Already expired

        XCTAssertTrue(apiKey.isExpired)

        let validated = await authService.validateAPIKey(apiKey.key)
        XCTAssertNil(validated, "Expired key should not validate")
    }

    func testCleanupExpiredKeys() async throws {
        _ = try await authService.createAPIKey(for: "test1", expiresIn: -1) // Expired
        _ = try await authService.createAPIKey(for: "test2", expiresIn: 3600) // Valid

        await authService.cleanupExpiredKeys()

        let keys = await authService.listKeys()
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.subdomain, "test2")
    }

    // MARK: - JWT Token Tests

    func testGenerateSessionToken() async throws {
        let tunnelID = UUID()
        let apiKey = try await authService.createAPIKey(for: "test")

        let token = try await authService.generateSessionToken(
            tunnelID: tunnelID,
            subdomain: "test",
            apiKey: apiKey.key,
            expiresIn: 3600
        )

        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(token.contains(".")) // JWT format: header.payload.signature
    }

    func testValidateSessionToken() async throws {
        let tunnelID = UUID()
        let apiKey = try await authService.createAPIKey(for: "test")

        let token = try await authService.generateSessionToken(
            tunnelID: tunnelID,
            subdomain: "test",
            apiKey: apiKey.key,
            expiresIn: 3600
        )

        let claims = try await authService.validateSessionToken(token)

        XCTAssertEqual(claims.sub, tunnelID.uuidString)
        XCTAssertEqual(claims.subdomain, "test")
        XCTAssertFalse(claims.isExpired)
    }

    func testValidateExpiredToken() async throws {
        let tunnelID = UUID()
        let apiKey = try await authService.createAPIKey(for: "test")

        let token = try await authService.generateSessionToken(
            tunnelID: tunnelID,
            subdomain: "test",
            apiKey: apiKey.key,
            expiresIn: -1 // Already expired
        )

        do {
            _ = try await authService.validateSessionToken(token)
            XCTFail("Should have thrown expired token error")
        } catch {
            // Expected
        }
    }

    func testRefreshSessionToken() async throws {
        let tunnelID = UUID()
        let apiKey = try await authService.createAPIKey(for: "test")

        let originalToken = try await authService.generateSessionToken(
            tunnelID: tunnelID,
            subdomain: "test",
            apiKey: apiKey.key,
            expiresIn: 3600
        )

        let refreshedToken = try await authService.refreshSessionToken(originalToken, expiresIn: 7200)

        XCTAssertNotEqual(originalToken, refreshedToken)

        let claims = try await authService.validateSessionToken(refreshedToken)
        XCTAssertEqual(claims.sub, tunnelID.uuidString)
        XCTAssertEqual(claims.subdomain, "test")
    }

    func testTokenWithInvalidSignature() async throws {
        let tunnelID = UUID()
        let apiKey = try await authService.createAPIKey(for: "test")

        let token = try await authService.generateSessionToken(
            tunnelID: tunnelID,
            subdomain: "test",
            apiKey: apiKey.key,
            expiresIn: 3600
        )

        // Tamper with the token
        let tamperedToken = token + "tampered"

        do {
            _ = try await authService.validateSessionToken(tamperedToken)
            XCTFail("Should have thrown invalid signature error")
        } catch {
            // Expected
        }
    }
}
