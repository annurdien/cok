import Foundation

/// Validates subdomain names for security and compliance
public struct SubdomainValidator: Sendable {
    
    // MARK: - Constants
    
    private static let minLength = 3
    private static let maxLength = 63
    
    // RFC 1123 compliant subdomain regex
    // Must start with alphanumeric, end with alphanumeric, can contain hyphens in between
    private static let subdomainPattern = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"
    
    // Reserved subdomains that cannot be used
    private static let reservedSubdomains: Set<String> = [
        "www", "api", "admin", "root", "system", "internal",
        "localhost", "staging", "production", "dev",
        "mail", "smtp", "pop", "imap", "ftp", "ssh",
        "vpn", "proxy", "gateway", "router", "firewall",
        "dashboard", "console", "panel", "control",
        "status", "health", "metrics", "monitoring"
    ]
    
    // Profanity filter - inappropriate words
    private static let profanityList: Set<String> = [
        "fuck", "shit", "damn", "hell", "ass", "bitch",
        "porn", "sex", "xxx", "nude", "nsfw", "rape"
    ]
    
    // MARK: - Validation Result
    
    public enum ValidationError: Error, Sendable {
        case tooShort(minimum: Int)
        case tooLong(maximum: Int)
        case invalidCharacters(pattern: String)
        case reserved(subdomain: String)
        case containsProfanity
        case startsWithHyphen
        case endsWithHyphen
        case consecutiveHyphens
        case empty
        
        public var message: String {
            switch self {
            case .tooShort(let min):
                return "Subdomain must be at least \(min) characters"
            case .tooLong(let max):
                return "Subdomain cannot exceed \(max) characters"
            case .invalidCharacters(let pattern):
                return "Subdomain must match pattern: \(pattern)"
            case .reserved(let subdomain):
                return "Subdomain '\(subdomain)' is reserved"
            case .containsProfanity:
                return "Subdomain contains inappropriate content"
            case .startsWithHyphen:
                return "Subdomain cannot start with a hyphen"
            case .endsWithHyphen:
                return "Subdomain cannot end with a hyphen"
            case .consecutiveHyphens:
                return "Subdomain cannot contain consecutive hyphens"
            case .empty:
                return "Subdomain cannot be empty"
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Validates a subdomain name
    /// - Parameter subdomain: The subdomain to validate
    /// - Returns: The validated subdomain in lowercase
    /// - Throws: ValidationError if validation fails
    public static func validate(_ subdomain: String) throws -> String {
        // Normalize to lowercase
        let normalized = subdomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if empty
        guard !normalized.isEmpty else {
            throw ValidationError.empty
        }
        
        // Check length
        guard normalized.count >= minLength else {
            throw ValidationError.tooShort(minimum: minLength)
        }
        
        guard normalized.count <= maxLength else {
            throw ValidationError.tooLong(maximum: maxLength)
        }
        
        // Check for hyphen at start/end
        guard !normalized.hasPrefix("-") else {
            throw ValidationError.startsWithHyphen
        }
        
        guard !normalized.hasSuffix("-") else {
            throw ValidationError.endsWithHyphen
        }
        
        // Check for consecutive hyphens
        guard !normalized.contains("--") else {
            throw ValidationError.consecutiveHyphens
        }
        
        // Check pattern match
        guard normalized.range(of: subdomainPattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidCharacters(pattern: subdomainPattern)
        }
        
        // Check reserved list
        guard !reservedSubdomains.contains(normalized) else {
            throw ValidationError.reserved(subdomain: normalized)
        }
        
        // Check profanity
        guard !containsProfanity(normalized) else {
            throw ValidationError.containsProfanity
        }
        
        return normalized
    }
    
    /// Checks if a subdomain is valid without throwing
    /// - Parameter subdomain: The subdomain to check
    /// - Returns: true if valid, false otherwise
    public static func isValid(_ subdomain: String) -> Bool {
        do {
            _ = try validate(subdomain)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private static func containsProfanity(_ subdomain: String) -> Bool {
        // Only check exact matches to avoid false positives
        // (e.g., "asset" shouldn't fail because it contains "ass")
        return profanityList.contains(subdomain)
    }
}
