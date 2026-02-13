import Crypto
import Foundation

/// JWT token generator and validator
public struct JWTService: Sendable {

    // MARK: - JWT Claims

    public struct Claims: Codable, Sendable {
        /// Subject (usually tunnel ID or user ID)
        public let sub: String

        /// Issued at timestamp
        public let iat: Int

        /// Expiration timestamp
        public let exp: Int

        /// Subdomain associated with this token
        public let subdomain: String

        /// API key hash (for verification)
        public let keyHash: String?

        public init(subject: String, subdomain: String, expiresIn: TimeInterval, keyHash: String? = nil) {
            self.sub = subject
            self.subdomain = subdomain
            self.keyHash = keyHash

            let now = Int(Date().timeIntervalSince1970)
            self.iat = now
            self.exp = now + Int(expiresIn)
        }

        /// Checks if the token is expired
        public var isExpired: Bool {
            let now = Int(Date().timeIntervalSince1970)
            return now >= exp
        }

        /// Time remaining until expiration
        public var timeUntilExpiration: TimeInterval {
            let now = Int(Date().timeIntervalSince1970)
            return TimeInterval(exp - now)
        }
    }

    // MARK: - Errors

    public enum Error: Swift.Error, Sendable {
        case invalidToken
        case expiredToken
        case invalidSignature
        case encodingFailed
        case decodingFailed
        case invalidFormat
    }

    // MARK: - Properties

    private let secret: SymmetricKey

    // MARK: - Initialization

    public init(secret: String) {
        let data = Data(secret.utf8)
        self.secret = SymmetricKey(data: SHA256.hash(data: data))
    }

    public init(secretKey: SymmetricKey) {
        self.secret = secretKey
    }

    // MARK: - Public Methods

    /// Generates a JWT token
    /// - Parameter claims: The claims to encode in the token
    /// - Returns: JWT token string
    /// - Throws: Error if encoding fails
    public func generateToken(claims: Claims) throws -> String {
        // Create header
        let header = ["alg": "HS256", "typ": "JWT"]

        // Encode header
        guard let headerData = try? JSONEncoder().encode(header) else {
            throw Error.encodingFailed
        }
        let headerBase64 = base64URLEncode(headerData)

        // Encode payload
        guard let payloadData = try? JSONEncoder().encode(claims) else {
            throw Error.encodingFailed
        }
        let payloadBase64 = base64URLEncode(payloadData)

        // Create signature
        let message = "\(headerBase64).\(payloadBase64)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: secret)
        let signatureBase64 = base64URLEncode(Data(signature))

        return "\(message).\(signatureBase64)"
    }

    /// Validates and decodes a JWT token
    /// - Parameter token: The JWT token string
    /// - Returns: Decoded claims
    /// - Throws: Error if validation fails
    public func validateToken(_ token: String) throws -> Claims {
        let parts = token.split(separator: ".").map(String.init)

        guard parts.count == 3 else {
            throw Error.invalidFormat
        }

        let headerBase64 = parts[0]
        let payloadBase64 = parts[1]
        let signatureBase64 = parts[2]

        // Verify signature using constant-time comparison
        let message = "\(headerBase64).\(payloadBase64)"
        guard let providedSignature = base64URLDecode(signatureBase64) else {
            throw Error.invalidSignature
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(providedSignature, authenticating: Data(message.utf8), using: secret) else {
            throw Error.invalidSignature
        }

        // Decode payload
        guard let payloadData = base64URLDecode(payloadBase64) else {
            throw Error.decodingFailed
        }

        guard let claims = try? JSONDecoder().decode(Claims.self, from: payloadData) else {
            throw Error.decodingFailed
        }

        // Check expiration
        guard !claims.isExpired else {
            throw Error.expiredToken
        }

        return claims
    }

    /// Refreshes a token (creates new token with same subject but new expiration)
    /// - Parameters:
    ///   - token: The token to refresh
    ///   - expiresIn: New expiration time
    /// - Returns: New JWT token
    /// - Throws: Error if validation or generation fails
    public func refreshToken(_ token: String, expiresIn: TimeInterval) throws -> String {
        let claims = try validateToken(token)
        let newClaims = Claims(
            subject: claims.sub,
            subdomain: claims.subdomain,
            expiresIn: expiresIn,
            keyHash: claims.keyHash
        )
        return try generateToken(claims: newClaims)
    }

    // MARK: - Private Methods

    private func base64URLEncode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }
}
