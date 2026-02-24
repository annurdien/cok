import Crypto
import Foundation
import TunnelCore

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

    public init(secret: String) {
        self.secret = secret
    }

    /// Verify a static HMAC key (subdomain:secret) — stateless, survives restarts.
    public func verifyStaticKey(_ key: String, subdomain: String) -> Bool {
        let message = subdomain
        guard let keyData = Data(hexString: key) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            keyData,
            authenticating: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
    }

    /// Validate a key: first try stateless HMAC, then fall back to in-memory registered keys.
    public func validateAPIKey(_ key: String, subdomain: String) -> APIKey? {
        if verifyStaticKey(key, subdomain: subdomain) {
            return APIKey(key: key, subdomain: subdomain)
        }
        guard let apiKey = apiKeys[key], !apiKey.isExpired else {
            return nil
        }
        guard apiKey.subdomain == subdomain else { return nil }
        return apiKey
    }

    public func createAPIKey(
        for subdomain: String,
        expiresIn: TimeInterval? = nil
    ) throws -> APIKey {
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

    public func cleanupExpiredKeys() {
        apiKeys = apiKeys.filter { !$0.value.isExpired }
    }
}

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
