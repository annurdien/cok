import Crypto
import Foundation

public struct APIKey: Sendable, Hashable {
    public let id: UUID
    public let key: String
    public let subdomain: String
    public let createdAt: Date

    public init(id: UUID = UUID(), key: String, subdomain: String, createdAt: Date = Date()) {
        self.id = id
        self.key = key
        self.subdomain = subdomain
        self.createdAt = createdAt
    }
}

public actor AuthService {
    private var apiKeys: [String: APIKey] = [:]
    private let secret: String

    public init(secret: String) {
        self.secret = secret
    }

    public func validateAPIKey(_ key: String) -> APIKey? {
        return apiKeys[key]
    }

    public func createAPIKey(for subdomain: String) throws -> APIKey {
        let keyData = "\(subdomain):\(UUID().uuidString):\(secret)".data(using: .utf8)!
        let hash = SHA256.hash(data: keyData)
        let keyString = hash.compactMap { String(format: "%02x", $0) }.joined()

        let apiKey = APIKey(key: keyString, subdomain: subdomain)
        apiKeys[keyString] = apiKey
        return apiKey
    }

    public func revokeAPIKey(_ key: String) {
        apiKeys.removeValue(forKey: key)
    }

    public func listKeys() -> [APIKey] {
        return Array(apiKeys.values)
    }
}
