import NIOCore
import NIOHTTP1
import XCTest

@testable import TunnelCore
@testable import TunnelServer

final class RequestConverterTests: XCTestCase {
    var converter: RequestConverter!

    override func setUp() {
        converter = RequestConverter()
    }

    func testConvertHTTPRequestToProtocolMessage() {
        let headers = HTTPHeaders([
            ("host", "example.com"),
            ("user-agent", "test"),
            ("content-type", "application/json"),
        ])

        let body = "test body"
        var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
        buffer.writeString(body)

        let request = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/api/test?param=value",
            headers: headers
        )

        let message = converter.toProtocolMessage(
            head: request,
            body: buffer,
            remoteAddress: "192.168.1.1"
        )

        XCTAssertEqual(message.method, "POST")
        XCTAssertEqual(message.path, "/api/test?param=value")
        XCTAssertEqual(message.remoteAddress, "192.168.1.1")
        XCTAssertEqual(message.body, buffer)

        XCTAssertTrue(message.headers.contains { $0.name == "host" && $0.value == "example.com" })
        XCTAssertTrue(message.headers.contains { $0.name == "user-agent" && $0.value == "test" })
        XCTAssertTrue(
            message.headers.contains { $0.name == "content-type" && $0.value == "application/json" }
        )
    }

    func testConvertEmptyBodyRequest() {
        let headers = HTTPHeaders([("host", "example.com")])
        let request = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )

        let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let message = converter.toProtocolMessage(
            head: request,
            body: emptyBuffer,
            remoteAddress: "localhost"
        )

        XCTAssertEqual(message.method, "GET")
        XCTAssertEqual(message.path, "/")
        XCTAssertEqual(message.body.readableBytes, 0)
    }

    func testConvertProtocolResponseToHTTPResponse() {
        let requestID = UUID()
        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 201,
            headers: [
                HTTPHeader(name: "content-type", value: "application/json"),
                HTTPHeader(name: "x-custom", value: "value"),
            ],
            body: ByteBuffer(string: "{\"status\":\"ok\"}")
        )

        let (head, bodyBuffer) = converter.toHTTPResponse(message: response)

        XCTAssertEqual(head.status.code, 201)
        XCTAssertEqual(head.headers["content-type"].first, "application/json")
        XCTAssertEqual(head.headers["x-custom"].first, "value")

        XCTAssertNotNil(bodyBuffer)
        if let buffer = bodyBuffer {
            let bodyString = buffer.getString(at: 0, length: buffer.readableBytes)
            XCTAssertEqual(bodyString, "{\"status\":\"ok\"}")
        }
    }

    func testConvertEmptyBodyResponse() {
        let requestID = UUID()
        let response = HTTPResponseMessage(
            requestID: requestID,
            statusCode: 204,
            headers: [],
            body: ByteBuffer()
        )

        let (head, bodyBuffer) = converter.toHTTPResponse(message: response)

        XCTAssertEqual(head.status.code, 204)
        XCTAssertNil(bodyBuffer)
    }

    func testPreserveAllHTTPHeaders() {
        let headers = HTTPHeaders([
            ("host", "example.com"),
            ("user-agent", "Mozilla/5.0"),
            ("accept", "text/html"),
            ("accept-encoding", "gzip, deflate"),
            ("accept-language", "en-US"),
            ("cookie", "session=abc123"),
        ])

        let request = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )

        let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let message = converter.toProtocolMessage(
            head: request,
            body: emptyBuffer,
            remoteAddress: "localhost"
        )

        XCTAssertEqual(message.headers.count, 6)
        XCTAssertTrue(message.headers.contains { $0.name == "host" && $0.value == "example.com" })
        XCTAssertTrue(
            message.headers.contains { $0.name == "cookie" && $0.value == "session=abc123" })
    }
}
