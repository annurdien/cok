import XCTest
import NIOCore
@testable import TunnelCore

final class RequestSizeValidatorTests: XCTestCase {
    
    func testValidateBodySizeWithinLimit() throws {
        XCTAssertNoThrow(try RequestSizeValidator.validateBodySize(1024))
        XCTAssertNoThrow(try RequestSizeValidator.validateBodySize(RequestSizeValidator.maxBodySize))
    }
    
    func testValidateBodySizeExceedsLimit() {
        XCTAssertThrowsError(try RequestSizeValidator.validateBodySize(RequestSizeValidator.maxBodySize + 1)) { error in
            guard case RequestSizeValidator.ValidationError.bodyTooLarge = error else {
                XCTFail("Expected bodyTooLarge error")
                return
            }
        }
    }
    
    func testValidateHeadersSizeWithinLimit() throws {
        XCTAssertNoThrow(try RequestSizeValidator.validateHeadersSize(1024))
        XCTAssertNoThrow(try RequestSizeValidator.validateHeadersSize(RequestSizeValidator.maxHeadersSize))
    }
    
    func testValidateHeadersSizeExceedsLimit() {
        XCTAssertThrowsError(try RequestSizeValidator.validateHeadersSize(RequestSizeValidator.maxHeadersSize + 1)) { error in
            guard case RequestSizeValidator.ValidationError.headersTooLarge = error else {
                XCTFail("Expected headersTooLarge error")
                return
            }
        }
    }
    
    func testValidateFrameSizeWithinLimit() throws {
        XCTAssertNoThrow(try RequestSizeValidator.validateFrameSize(1024))
        XCTAssertNoThrow(try RequestSizeValidator.validateFrameSize(RequestSizeValidator.maxWebSocketFrameSize))
    }
    
    func testValidateFrameSizeExceedsLimit() {
        XCTAssertThrowsError(try RequestSizeValidator.validateFrameSize(RequestSizeValidator.maxWebSocketFrameSize + 1)) { error in
            guard case RequestSizeValidator.ValidationError.frameTooLarge = error else {
                XCTFail("Expected frameTooLarge error")
                return
            }
        }
    }
    
    func testValidateHeaderCountWithinLimit() throws {
        XCTAssertNoThrow(try RequestSizeValidator.validateHeaderCount(50))
        XCTAssertNoThrow(try RequestSizeValidator.validateHeaderCount(RequestSizeValidator.maxHeaderCount))
    }
    
    func testValidateHeaderCountExceedsLimit() {
        XCTAssertThrowsError(try RequestSizeValidator.validateHeaderCount(RequestSizeValidator.maxHeaderCount + 1)) { error in
            guard case RequestSizeValidator.ValidationError.tooManyHeaders = error else {
                XCTFail("Expected tooManyHeaders error")
                return
            }
        }
    }
    
    func testValidatePathWithinLimit() throws {
        let validPath = String(repeating: "a", count: RequestSizeValidator.maxPathLength)
        XCTAssertNoThrow(try RequestSizeValidator.validatePath("/api/test"))
        XCTAssertNoThrow(try RequestSizeValidator.validatePath(validPath))
    }
    
    func testValidatePathExceedsLimit() {
        let longPath = String(repeating: "a", count: RequestSizeValidator.maxPathLength + 1)
        XCTAssertThrowsError(try RequestSizeValidator.validatePath(longPath)) { error in
            guard case RequestSizeValidator.ValidationError.pathTooLong = error else {
                XCTFail("Expected pathTooLong error")
                return
            }
        }
    }
    
    func testValidateSubdomainWithinLimit() throws {
        let validSubdomain = String(repeating: "a", count: RequestSizeValidator.maxSubdomainLength)
        XCTAssertNoThrow(try RequestSizeValidator.validateSubdomain("myapp"))
        XCTAssertNoThrow(try RequestSizeValidator.validateSubdomain(validSubdomain))
    }
    
    func testValidateSubdomainExceedsLimit() {
        let longSubdomain = String(repeating: "a", count: RequestSizeValidator.maxSubdomainLength + 1)
        XCTAssertThrowsError(try RequestSizeValidator.validateSubdomain(longSubdomain)) { error in
            guard case RequestSizeValidator.ValidationError.subdomainTooLong = error else {
                XCTFail("Expected subdomainTooLong error")
                return
            }
        }
    }
    
    func testValidateBufferSize() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        buffer.writeBytes(Array(repeating: UInt8(0), count: 512))
        XCTAssertNoThrow(try RequestSizeValidator.validateBufferSize(buffer))
    }
    
    func testValidateHeaderValue() throws {
        XCTAssertNoThrow(try RequestSizeValidator.validateHeaderValue("application/json"))
        
        let longValue = String(repeating: "x", count: RequestSizeValidator.maxHeaderValueLength + 1)
        XCTAssertThrowsError(try RequestSizeValidator.validateHeaderValue(longValue)) { error in
            guard case RequestSizeValidator.ValidationError.headerValueTooLong = error else {
                XCTFail("Expected headerValueTooLong error")
                return
            }
        }
    }
    
    func testFormatSize() {
        XCTAssertEqual(RequestSizeValidator.formatSize(512), "512 B")
        XCTAssertEqual(RequestSizeValidator.formatSize(1024), "1.00 KB")
        XCTAssertEqual(RequestSizeValidator.formatSize(1024 * 1024), "1.00 MB")
        XCTAssertEqual(RequestSizeValidator.formatSize(1024 * 1024 * 1024), "1.00 GB")
    }
    
    func testErrorMessages() {
        let bodyError = RequestSizeValidator.ValidationError.bodyTooLarge(size: 100, maximum: 50)
        XCTAssertTrue(bodyError.message.contains("100"))
        XCTAssertTrue(bodyError.message.contains("50"))
        
        let headersError = RequestSizeValidator.ValidationError.headersTooLarge(size: 200, maximum: 100)
        XCTAssertTrue(headersError.message.contains("200"))
        
        let countError = RequestSizeValidator.ValidationError.tooManyHeaders(count: 150, maximum: 100)
        XCTAssertTrue(countError.message.contains("150"))
    }
}
