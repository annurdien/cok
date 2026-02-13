import XCTest
@testable import TunnelCore

final class InputSanitizerTests: XCTestCase {
    
    func testSanitizeStringValid() throws {
        let validInputs = [
            "hello world",
            "test-string_123",
            "normal text with spaces",
            "multi\nline\ntext"
        ]
        
        for input in validInputs {
            XCTAssertNoThrow(try InputSanitizer.sanitizeString(input))
        }
    }
    
    func testSanitizeStringTooLong() {
        let tooLong = String(repeating: "a", count: 2000)
        XCTAssertThrowsError(try InputSanitizer.sanitizeString(tooLong)) { error in
            guard case InputSanitizer.SanitizationError.tooLong = error else {
                XCTFail("Expected tooLong error, got \(error)")
                return
            }
        }
    }
    
    func testSanitizeStringWithControlCharacters() {
        let withControlChars = "test\u{0000}string"
        XCTAssertThrowsError(try InputSanitizer.sanitizeString(withControlChars)) { error in
            guard case InputSanitizer.SanitizationError.controlCharacters = error else {
                XCTFail("Expected controlCharacters error, got \(error)")
                return
            }
        }
    }
    
    func testSanitizeStringSQLInjection() {
        let sqlInjectionAttempts = [
            "'; DROP TABLE users--",
            "1' OR '1'='1",
            "admin'--",
            "1; DELETE FROM users"
        ]
        
        for attempt in sqlInjectionAttempts {
            XCTAssertThrowsError(try InputSanitizer.sanitizeString(attempt)) { error in
                 guard case InputSanitizer.SanitizationError.containsSQLInjection = error else {
                    XCTFail("Expected SQL injection error for '\(attempt)', got \(error)")
                    return
                }
            }
        }
    }
    
    func testSanitizeStringXSS() {
        let xssAttempts = [
            "<script>alert('xss')</script>",
            "javascript:alert('xss')",
            "<iframe src='evil.com'>",
            "onerror=alert('xss')"
        ]
        
        for attempt in xssAttempts {
            XCTAssertThrowsError(try InputSanitizer.sanitizeString(attempt)) { error in
                guard case InputSanitizer.SanitizationError.containsXSS = error else {
                    XCTFail("Expected XSS error for '\(attempt)', got \(error)")
                    return
                }
            }
        }
    }
    
    func testSanitizeHeaderValue() throws {
        let validHeaders = [
            "application/json",
            "Bearer token123",
            "en-US,en;q=0.9"
        ]
        
        for header in validHeaders {
            XCTAssertNoThrow(try InputSanitizer.sanitizeHeaderValue(header))
        }
    }
    
    func testSanitizeHeaderValueTooLong() {
        let tooLong = String(repeating: "a", count: 10000)
        XCTAssertThrowsError(try InputSanitizer.sanitizeHeaderValue(tooLong))
    }
    
    func testSanitizePath() throws {
        let validPaths = [
            "/api/v1/users",
            "/path/to/resource",
            "/test"
        ]
        
        for path in validPaths {
            XCTAssertNoThrow(try InputSanitizer.sanitizePath(path))
        }
    }
    
    func testSanitizePathTraversal() {
        let traversalAttempts = [
            "../../../etc/passwd",
            "/path/../../../secret",
            "..\\..\\..\\windows\\system32"
        ]
        
        for attempt in traversalAttempts {
            XCTAssertThrowsError(try InputSanitizer.sanitizePath(attempt)) { error in
                guard case InputSanitizer.SanitizationError.containsPathTraversal = error else {
                    XCTFail("Expected path traversal error for '\(attempt)', got \(error)")
                    return
                }
            }
        }
    }
    
    func testSanitizePathAddsLeadingSlash() throws {
        let path = try InputSanitizer.sanitizePath("api/users")
        XCTAssertEqual(path, "/api/users")
    }
    
    func testValidateAPIKey() throws {
        // Valid 64-character hex string (SHA256 output)
        let validKey = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try InputSanitizer.validateAPIKey(validKey))
    }
    
    func testValidateAPIKeyInvalidLength() {
        let invalidKeys = [
            "short",
            String(repeating: "a", count: 32), // Too short
            String(repeating: "a", count: 128)  // Too long
        ]
        
        for key in invalidKeys {
            XCTAssertThrowsError(try InputSanitizer.validateAPIKey(key))
        }
    }
    
    func testValidateAPIKeyInvalidCharacters() {
        let invalidKey = String(repeating: "x", count: 64)
        // 'x' is valid hex, but let's test with truly invalid chars
        let reallyInvalid = String(repeating: "g", count: 64)
        XCTAssertThrowsError(try InputSanitizer.validateAPIKey(reallyInvalid))
    }
    
    func testSanitizeSubdomain() throws {
        XCTAssertEqual(try InputSanitizer.sanitizeSubdomain("  Test-App  "), "test-app")
        XCTAssertThrowsError(try InputSanitizer.sanitizeSubdomain("admin"))
    }
}
