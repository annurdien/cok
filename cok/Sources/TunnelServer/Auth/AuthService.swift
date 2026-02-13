import Crypto
import Foundation

public struct APIKey: Sendable, Hashable {
    public let id: UUID
    public let key: String
    public let subdomain: String
    public let createdAt: Date
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(),
        key: String,
        subdomain: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.subdomain = subdomain
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
    
    /// Checks if the API key is expired
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else {
            return false
        }
        return Date() >= expiresAt
    }
}

public actor AuthService {
    private var apiKeys: [String: APIKey] = [:]
    private let secret: String
    private let jwtService: JWTService

    public init(secret: String) {
        self.secret = secret
        self.jwtService = JWTService(secret: secret)
    }

    // MARK: - API Key Management

    public func validateAPIKey(_ key: String) -> APIKey? {
        guard let apiKey = apiKeys[key], !apiKey.isExpired else {
            return nil
        }
        return apiKey
    }

    public func createAPIKey(for subdomain: String, expiresIn: TimeInterval? = nil) throws -> APIKey {
        // Use HMAC-SHA256 for API key generation
        let timestamp = Date().timeIntervalSince1970
        let message = "\(subdomain):\(UUID().uuidString):\(timestamp)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        let keyString = signature.compactMap { String(format: "%02x", $0) }.joined()

        let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }
        let apiKey = APIKey(key: keyString, subdomain: subdomain, expiresAt: expiresAt)
        apiKeys[keyString] = apiKey
        return apiKey
    }

    public func revokeAPIKey(_ key: String) {
        apiKeys.removeValue(forKey: key)
    }

    public func listKeys() -> [APIKey] {
        return Array(apiKeys.values)
    }
    
    /// Verifies an API key using HMAC validation
    /// This allows verification without storing keys in memory (stateless)
    public func verifyAPIKeyHMAC(_ key: String, subdomain: String, timestamp: TimeInterval) -> Bool {
        let message = "\(subdomain):\(timestamp)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        let expectedKey = signature.compactMap { String(format: "%02x", $0) }.joined()
        
        return key == expectedKey
    }
    
    // MARK: - JWT Token Management
    
    /// Generates a session token for an authenticated tunnel
    public func generateSessionToken(
        tunnelID: UUID,
        subdomain: String,
        apiKey: String,
        expiresIn: TimeInterval = 86400  // 24 hours
    ) throws -> String {
        let claims = JWTService.Claims(
            subject: tunnelID.uuidString,
            subdomain: subdomain,
            expiresIn: expiresIn,
            keyHash: SHA256.hash(data: Data(apiKey.utf8))
                .compactMap { String(format: "%02x", $0) }
                .joined()
        )
        
        return try jwtService.generateToken(claims: claims)
    }
    
    /// Validates a session token
    public func validateSessionToken(_ token: String) throws -> JWTService.Claims {
        return try jwtService.validateToken(token)
    }
    
    /// Refreshes a session token
    public func refreshSessionToken(_ token: String, expiresIn: TimeInterval = 86400) throws -> String {
        return try jwtService.refreshToken(token, expiresIn: expiresIn)
    }
    
    // MARK: - Cleanup
    
    /// Removes expired API keys
    public func cleanupExpiredKeys() {
        apiKeys = apiKeys.filter { !$0.value.isExpired }
    }
}

