import Foundation

/// Sanitizes and validates user inputs for security
public struct InputSanitizer: Sendable {
    
    // MARK: - Constants
    
    public static let maxStringLength = 1024
    public static let maxHeaderValueLength = 8192
    public static let maxURLLength = 2048
    
    // Dangerous patterns that should be rejected
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
    
    // MARK: - Validation Errors
    
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
            case .tooLong(let max, let actual):
                return "Input too long: \(actual) characters (max: \(max))"
            case .containsDangerousPattern(let pattern):
                return "Input contains dangerous pattern: \(pattern)"
            case .containsSQLInjection:
                return "Input contains potential SQL injection"
            case .containsXSS:
                return "Input contains potential XSS attack"
            case .containsPathTraversal:
                return "Input contains path traversal attempt"
            case .controlCharacters:
                return "Input contains control characters"
            case .invalidUTF8:
                return "Input is not valid UTF-8"
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Sanitizes a general string input
    /// - Parameter input: The string to sanitize
    /// - Returns: Sanitized string
    /// - Throws: SanitizationError if input is malicious
    public static func sanitizeString(_ input: String, maxLength: Int = maxStringLength) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check length
        guard trimmed.count <= maxLength else {
            throw SanitizationError.tooLong(maximum: maxLength, actual: trimmed.count)
        }
        
        // Check for control characters (except newline and tab)
        guard !containsControlCharacters(trimmed) else {
            throw SanitizationError.controlCharacters
        }
        
        // Check for SQL injection
        try checkSQLInjection(trimmed)
        
        // Check for XSS
        try checkXSS(trimmed)
        
        return trimmed
    }
    
    /// Sanitizes an HTTP header value
    /// - Parameter value: The header value to sanitize
    /// - Returns: Sanitized header value
    /// - Throws: SanitizationError if value is malicious
    public static func sanitizeHeaderValue(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check length
        guard trimmed.count <= maxHeaderValueLength else {
            throw SanitizationError.tooLong(maximum: maxHeaderValueLength, actual: trimmed.count)
        }
        
        // Header values should not contain control characters except tab
        let allowedControlChars = CharacterSet(charactersIn: "\t")
        let controlChars = CharacterSet.controlCharacters.subtracting(allowedControlChars)
        
        guard trimmed.rangeOfCharacter(from: controlChars) == nil else {
            throw SanitizationError.controlCharacters
        }
        
        return trimmed
    }
    
    /// Sanitizes a URL path
    /// - Parameter path: The URL path to sanitize
    /// - Returns: Sanitized path
    /// - Throws: SanitizationError if path is malicious
    public static func sanitizePath(_ path: String) throws -> String {
        guard path.count <= maxURLLength else {
            throw SanitizationError.tooLong(maximum: maxURLLength, actual: path.count)
        }
        
        // Check for path traversal
        try checkPathTraversal(path)
        
        // URL paths should start with /
        if !path.hasPrefix("/") {
            return "/" + path
        }
        
        return path
    }
    
    /// Validates an API key format
    /// - Parameter apiKey: The API key to validate
    /// - Returns: The validated API key
    /// - Throws: SanitizationError if format is invalid
    public static func validateAPIKey(_ apiKey: String) throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // API keys should be hex strings of specific length (64 for SHA256)
        guard trimmed.count == 64 else {
            throw SanitizationError.tooLong(maximum: 64, actual: trimmed.count)
        }
        
        // Check if it's all hexadecimal
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard trimmed.rangeOfCharacter(from: hexCharacterSet.inverted) == nil else {
            throw SanitizationError.containsDangerousPattern(pattern: "non-hex characters")
        }
        
        return trimmed.lowercased()
    }
    
    /// Sanitizes a subdomain (delegates to SubdomainValidator)
    /// - Parameter subdomain: The subdomain to sanitize
    /// - Returns: Sanitized subdomain
    /// - Throws: SanitizationError or SubdomainValidator.ValidationError
    public static func sanitizeSubdomain(_ subdomain: String) throws -> String {
        return try SubdomainValidator.validate(subdomain)
    }
    
    // MARK: - Private Methods
    
    private static func containsControlCharacters(_ input: String) -> Bool {
        let allowedControlChars = CharacterSet(charactersIn: "\n\t\r")
        let dangerousControlChars = CharacterSet.controlCharacters.subtracting(allowedControlChars)
        return input.rangeOfCharacter(from: dangerousControlChars) != nil
    }
    
    private static func checkSQLInjection(_ input: String) throws {
        for pattern in sqlInjectionPatterns {
            if input.range(of: pattern, options: .regularExpression) != nil {
                throw SanitizationError.containsSQLInjection
            }
        }
    }
    
    private static func checkXSS(_ input: String) throws {
        for pattern in xssPatterns {
            if input.range(of: pattern, options: .regularExpression) != nil {
                throw SanitizationError.containsXSS
            }
        }
    }
    
    private static func checkPathTraversal(_ input: String) throws {
        for pattern in pathTraversalPatterns {
            if input.range(of: pattern, options: .regularExpression) != nil {
                throw SanitizationError.containsPathTraversal
            }
        }
    }
}
