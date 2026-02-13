import Foundation

public struct InputSanitizer: Sendable {
    
    public static let maxStringLength = 1024
    public static let maxHeaderValueLength = 8192
    public static let maxURLLength = 2048
    
    private static let sqlInjectionPatterns = [
        "(?i)(union.*select)", "(?i)(insert.*into)", "(?i)(drop.*table)",
        "(?i)(delete.*from)", "(?i)(update.*set)", "(--|;)", "(?i)(or\\s+'?\\d+'?\\s*=\\s*'?\\d+'?)"
    ]
    
    private static let xssPatterns = [
        "(?i)(<script)", "(?i)(javascript:)", "(?i)(onerror=)",
        "(?i)(onload=)", "(?i)(<iframe)", "(?i)(eval\\()"
    ]
    
    private static let pathTraversalPatterns = [
        "\\.\\./", "\\.\\\\", "/\\.\\.", "\\\\\\.\\./"
    ]
    
    public enum SanitizationError: Error, Sendable {
        case tooLong(maximum: Int, actual: Int)
        case containsDangerousPattern(pattern: String)
        case containsSQLInjection
        case containsXSS
        case containsPathTraversal
        case controlCharacters
        case invalidUTF8
        
        public var message: String {
            switch self {
            case .tooLong(let max, let actual): return "Input too long: \(actual) chars (max: \(max))"
            case .containsDangerousPattern(let p): return "Dangerous pattern: \(p)"
            case .containsSQLInjection: return "Potential SQL injection"
            case .containsXSS: return "Potential XSS attack"
            case .containsPathTraversal: return "Path traversal attempt"
            case .controlCharacters: return "Contains control characters"
            case .invalidUTF8: return "Invalid UTF-8"
            }
        }
    }
    
    public static func sanitizeString(_ input: String, maxLength: Int = maxStringLength) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxLength else {
            throw SanitizationError.tooLong(maximum: maxLength, actual: trimmed.count)
        }
        guard !containsControlCharacters(trimmed) else { throw SanitizationError.controlCharacters }
        try checkSQLInjection(trimmed)
        try checkXSS(trimmed)
        return trimmed
    }
    
    public static func sanitizeHeaderValue(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxHeaderValueLength else {
            throw SanitizationError.tooLong(maximum: maxHeaderValueLength, actual: trimmed.count)
        }
        let controlChars = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t"))
        guard trimmed.rangeOfCharacter(from: controlChars) == nil else {
            throw SanitizationError.controlCharacters
        }
        return trimmed
    }
    
    public static func sanitizePath(_ path: String) throws -> String {
        guard path.count <= maxURLLength else {
            throw SanitizationError.tooLong(maximum: maxURLLength, actual: path.count)
        }
        try checkPathTraversal(path)
        return path.hasPrefix("/") ? path : "/" + path
    }
    
    public static func validateAPIKey(_ apiKey: String) throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else {
            throw SanitizationError.tooLong(maximum: 64, actual: trimmed.count)
        }
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard trimmed.rangeOfCharacter(from: hexChars.inverted) == nil else {
            throw SanitizationError.containsDangerousPattern(pattern: "non-hex characters")
        }
        return trimmed.lowercased()
    }
    
    public static func sanitizeSubdomain(_ subdomain: String) throws -> String {
        try SubdomainValidator.validate(subdomain)
    }
    
    private static func containsControlCharacters(_ input: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "\n\t\r")
        return input.rangeOfCharacter(from: CharacterSet.controlCharacters.subtracting(allowed)) != nil
    }
    
    private static func checkSQLInjection(_ input: String) throws {
        for pattern in sqlInjectionPatterns where input.range(of: pattern, options: .regularExpression) != nil {
            throw SanitizationError.containsSQLInjection
        }
    }
    
    private static func checkXSS(_ input: String) throws {
        for pattern in xssPatterns where input.range(of: pattern, options: .regularExpression) != nil {
            throw SanitizationError.containsXSS
        }
    }
    
    private static func checkPathTraversal(_ input: String) throws {
        for pattern in pathTraversalPatterns where input.range(of: pattern, options: .regularExpression) != nil {
            throw SanitizationError.containsPathTraversal
        }
    }
}
