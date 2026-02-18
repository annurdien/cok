import Foundation
import NIOCore
import NIOHTTP1

public enum HTTPConversion {
    public static func toRequestMessage(
        head: HTTPRequestHead,
        body: ByteBuffer,
        remoteAddress: String,
        requestID: UUID = UUID()
    ) -> HTTPRequestMessage {
        let headers = head.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
        return HTTPRequestMessage(
            requestID: requestID,
            method: head.method.rawValue,
            path: head.uri,
            headers: headers,
            body: body,
            remoteAddress: remoteAddress
        )
    }

    public static func toHTTPResponse(
        message: HTTPResponseMessage
    ) -> (head: HTTPResponseHead, body: ByteBuffer?) {
        let status = HTTPResponseStatus(statusCode: Int(message.statusCode))
        var headers = HTTPHeaders()

        for header in message.headers {
            headers.add(name: header.name, value: header.value)
        }

        if !headers.contains(name: "Content-Length") {
            headers.add(name: "Content-Length", value: "\(message.body.readableBytes)")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        let body: ByteBuffer? = message.body.readableBytes > 0 ? message.body : nil

        return (head: head, body: body)
    }
}
