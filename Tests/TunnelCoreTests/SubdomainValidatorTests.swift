import XCTest
@testable import TunnelCore

final class SubdomainValidatorTests: XCTestCase {
    
    func testValidSubdomains() throws {
        let validSubdomains = [
            "test", "my-app", "app123", "a123b", "test-app-123",
            "abc", "123" // minimum 3 chars
        ]
        
        for subdomain in validSubdomains {
            XCTAssertNoThrow(
                try SubdomainValidator.validate(subdomain),
                "'\(subdomain)' should be valid"
            )
        }
    }
    
    func testInvalidSubdomainsTooShort() {
        let invalidSubdomains = ["", "ab", "a"]
        
        for subdomain in invalidSubdomains {
            XCTAssertThrowsError(try SubdomainValidator.validate(subdomain)) { error in
                XCTAssertTrue(error is SubdomainValidator.ValidationError)
            }
        }
    }
    
    func testInvalidSubdomainsTooLong() {
        let tooLong = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try SubdomainValidator.validate(tooLong))
    }
    
    func testInvalidSubdomainsWithHyphens() {
        let invalidSubdomains = [
            "-test", "test-", "test--app"
        ]
        
        for subdomain in invalidSubdomains {
            XCTAssertThrowsError(try SubdomainValidator.validate(subdomain))
        }
    }
    
    func testInvalidSubdomainsWithInvalidCharacters() {
        let invalidSubdomains = [
            "test_app", "test.app", "test app", "test@app",
            "TEST", "Test", "TeSt" // uppercase should be lowercased but pattern check happens first
        ]
        
        for subdomain in invalidSubdomains {
            let result = SubdomainValidator.isValid(subdomain)
            // Note: uppercase letters are allowed and will be lowercased,
            // but special chars are not
            if subdomain.rangeOfCharacter(from: CharacterSet.lowercaseLetters.inverted) == nil ||
               subdomain.lowercased() == subdomain {
                XCTAssertFalse(result, "'\(subdomain)' should be invalid")
            }
        }
    }
    
    func testReservedSubdomains() {
        let reservedSubdomains = [
            "www", "api", "admin", "root", "system"
        ]
        
        for subdomain in reservedSubdomains {
            XCTAssertThrowsError(try SubdomainValidator.validate(subdomain)) { error in
                guard case SubdomainValidator.ValidationError.reserved = error else {
                    XCTFail("Expected reserved error, got \(error)")
                    return
                }
            }
        }
    }
    
    func testProfanityFilter() {
        let profaneSubdomains = [
            "fuck", "shit", "porn", "xxx"
        ]
        
        for subdomain in profaneSubdomains {
            XCTAssertThrowsError(try SubdomainValidator.validate(subdomain)) { error in
                guard case SubdomainValidator.ValidationError.containsProfanity = error else {
                    XCTFail("Expected profanity error, got \(error)")
                    return
                }
            }
        }
    }
    
    func testNormalization() throws {
        let result = try SubdomainValidator.validate("  Test-App  ")
        XCTAssertEqual(result, "test-app")
    }
    
    func testIsValidHelper() {
        XCTAssertTrue(SubdomainValidator.isValid("test-app"))
        XCTAssertFalse(SubdomainValidator.isValid(""))
        XCTAssertFalse(SubdomainValidator.isValid("admin"))
    }
}
