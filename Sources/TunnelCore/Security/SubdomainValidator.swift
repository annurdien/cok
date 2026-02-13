import Foundation

public struct SubdomainValidator: Sendable {

    private static let minLength = 3
    private static let maxLength = 63
    private static let subdomainPattern = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"

    private static let reservedSubdomains: Set<String> = [
        "www", "api", "admin", "root", "system", "internal",
        "localhost", "staging", "production", "dev",
        "mail", "smtp", "pop", "imap", "ftp", "ssh",
        "vpn", "proxy", "gateway", "router", "firewall",
        "dashboard", "console", "panel", "control",
        "status", "health", "metrics", "monitoring"
    ]

    private static let profanityList: Set<String> = [
        "fuck", "shit", "damn", "hell", "ass", "bitch",
        "porn", "sex", "xxx", "nude", "nsfw", "rape"
    ]

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
            case .tooShort(let min): return "Subdomain must be at least \(min) characters"
            case .tooLong(let max): return "Subdomain cannot exceed \(max) characters"
            case .invalidCharacters: return "Subdomain contains invalid characters"
            case .reserved(let subdomain): return "Subdomain '\(subdomain)' is reserved"
            case .containsProfanity: return "Subdomain contains inappropriate content"
            case .startsWithHyphen: return "Subdomain cannot start with a hyphen"
            case .endsWithHyphen: return "Subdomain cannot end with a hyphen"
            case .consecutiveHyphens: return "Subdomain cannot contain consecutive hyphens"
            case .empty: return "Subdomain cannot be empty"
            }
        }
    }

    public static func validate(_ subdomain: String) throws -> String {
        let normalized = subdomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { throw ValidationError.empty }
        guard normalized.count >= minLength else { throw ValidationError.tooShort(minimum: minLength) }
        guard normalized.count <= maxLength else { throw ValidationError.tooLong(maximum: maxLength) }
        guard !normalized.hasPrefix("-") else { throw ValidationError.startsWithHyphen }
        guard !normalized.hasSuffix("-") else { throw ValidationError.endsWithHyphen }
        guard !normalized.contains("--") else { throw ValidationError.consecutiveHyphens }
        guard normalized.range(of: subdomainPattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidCharacters(pattern: subdomainPattern)
        }
        guard !reservedSubdomains.contains(normalized) else { throw ValidationError.reserved(subdomain: normalized) }
        guard !profanityList.contains(normalized) else { throw ValidationError.containsProfanity }

        return normalized
    }

    public static func isValid(_ subdomain: String) -> Bool {
        (try? validate(subdomain)) != nil
    }
}
