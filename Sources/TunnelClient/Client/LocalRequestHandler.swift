import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import TunnelCore

public actor LocalRequestHandler {
    private let tcpClient: TunnelTCPClient
    private let circuitBreaker: CircuitBreaker
    private let logger: Logger
    private let config: ClientConfig
    private let codec: BinaryMessageCodec
    private var pendingRequests: [UUID: CheckedContinuation<HTTPResponseMessage, Error>] = [:]
    private let httpClient: HTTPClient

    public init(
        tcpClient: TunnelTCPClient,
        circuitBreaker: CircuitBreaker,
        config: ClientConfig,
        logger: Logger
    ) {
        self.tcpClient = tcpClient
        self.circuitBreaker = circuitBreaker
        self.config = config
        self.logger = logger
        self.codec = BinaryMessageCodec()
        self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    }

    public func handleRequest(
        head: HTTPRequestHead,
        body: ByteBuffer
    ) async throws -> (HTTPResponseHead, ByteBuffer?) {
        guard await circuitBreaker.canAttempt() else {
            logger.warning("Circuit breaker is open, rejecting request")
            let err = ClientError.localServerUnreachable(
                host: config.localHost, port: config.localPort)
            throw TunnelError.client(err, context: ErrorContext(component: "RequestHandler"))
        }

        guard await tcpClient.isConnected() else {
            await circuitBreaker.recordFailure()
            let err = ClientError.connectionFailed("Not connected to tunnel server")
            throw TunnelError.client(err, context: ErrorContext(component: "RequestHandler"))
        }

        let requestID = UUID()
        let requestMessage = convertToProtocolMessage(head: head, body: body, requestID: requestID)

        do {
            let response = try await sendAndWaitForResponse(
                requestID: requestID, request: requestMessage)
            await circuitBreaker.recordSuccess()
            return convertToHTTPResponse(response)
        } catch {
            await circuitBreaker.recordFailure()
            throw error
        }
    }

    private func sendAndWaitForResponse(
        requestID: UUID,
        request: HTTPRequestMessage
    ) async throws -> HTTPResponseMessage {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        self.storeContinuation(requestID: requestID, continuation: continuation)

                        let buffer = try self.codec.encode(request)

                        let frame = try ProtocolFrame(
                            version: .current,
                            messageType: .httpRequest,
                            flags: [],
                            payload: buffer
                        )

                        try await self.tcpClient.sendFrame(frame)

                        self.logger.debug(
                            "Sent request to tunnel",
                            metadata: [
                                "requestID": "\(requestID.uuidString.prefix(8))",
                                "method": "\(request.method)",
                                "path": "\(request.path)",
                            ])

                        Task {
                            try await Task.sleep(for: .seconds(self.config.requestTimeout))

                            guard
                                let storedContinuation = self.removeContinuation(
                                    requestID: requestID)
                            else {
                                return
                            }

                            self.logger.warning(
                                "Request timeout",
                                metadata: [
                                    "requestID": "\(requestID.uuidString.prefix(8))"
                                ])

                            let err = TunnelError.client(
                                .timeout,
                                context: ErrorContext(component: "RequestHandler")
                            )
                            storedContinuation.resume(throwing: err)
                        }
                    } catch {
                        _ = self.removeContinuation(requestID: requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelRequest(requestID: requestID)
            }
        }
    }

    private func storeContinuation(
        requestID: UUID, continuation: CheckedContinuation<HTTPResponseMessage, Error>
    ) {
        pendingRequests[requestID] = continuation
    }

    private func removeContinuation(requestID: UUID) -> CheckedContinuation<
        HTTPResponseMessage, Error
    >? {
        return pendingRequests.removeValue(forKey: requestID)
    }

    private func cancelRequest(requestID: UUID) {
        if let continuation = pendingRequests.removeValue(forKey: requestID) {
            logger.debug(
                "Request cancelled",
                metadata: [
                    "requestID": "\(requestID.uuidString.prefix(8))"
                ])

            continuation.resume(throwing: CancellationError())
        }
    }

    public func handleIncomingMessage(_ frame: ProtocolFrame) {
        Task {
            do {
                switch frame.messageType {
                case .connectResponse:
                    try await handleConnectResponse(frame)
                case .httpRequest:
                    try await handleHTTPRequest(frame)
                case .httpResponse:
                    try await handleHTTPResponse(frame)
                case .pong:
                    logger.debug("Received pong from server")
                case .error:
                    try await handleError(frame)
                default:
                    logger.warning(
                        "Unexpected message type",
                        metadata: [
                            "type": "\(frame.messageType)"
                        ])
                }
            } catch {
                logger.error(
                    "Error handling incoming message",
                    metadata: [
                        "error": "\(error.localizedDescription)"
                    ])
            }
        }
    }

    private func handleHTTPRequest(_ frame: ProtocolFrame) async throws {
        let request = try codec.decode(HTTPRequestMessage.self, from: frame.payload)

        logger.debug(
            "Received request from tunnel",
            metadata: [
                "requestID": "\(request.requestID.uuidString.prefix(8))",
                "method": "\(request.method)",
                "path": "\(request.path)",
            ])

        do {
            let response = try await forwardToLocalServer(request)

            let responseBuffer = try codec.encode(response)

            let responseFrame = try ProtocolFrame(
                version: .current,
                messageType: .httpResponse,
                flags: [],
                payload: responseBuffer
            )

            try await tcpClient.sendFrame(responseFrame)

            logger.debug(
                "Sent response back through tunnel",
                metadata: [
                    "requestID": "\(request.requestID.uuidString.prefix(8))",
                    "status": "\(response.statusCode)",
                ])
        } catch {
            logger.error(
                "Failed to forward request to local server",
                metadata: [
                    "requestID": "\(request.requestID.uuidString.prefix(8))",
                    "error": "\(error.localizedDescription)",
                ])

            let errorResponse = HTTPResponseMessage(
                requestID: request.requestID,
                statusCode: 502,
                headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                body: Data("Bad Gateway: Failed to reach local server".utf8)
            )

            let responseBuffer = try codec.encode(errorResponse)

            let responseFrame = try ProtocolFrame(
                version: .current,
                messageType: .httpResponse,
                flags: [],
                payload: responseBuffer
            )

            try await tcpClient.sendFrame(responseFrame)
        }
    }

    private func forwardToLocalServer(
        _ request: HTTPRequestMessage
    ) async throws -> HTTPResponseMessage {
        let urlString = "http://\(config.localHost):\(config.localPort)\(request.path)"

        var httpRequest = HTTPClientRequest(url: urlString)
        httpRequest.method = HTTPMethod(rawValue: request.method)

        for header in request.headers {
            httpRequest.headers.add(name: header.name, value: header.value)
        }

        if !request.body.isEmpty {
            httpRequest.body = .bytes(request.body)
        }

        let response = try await httpClient.execute(httpRequest, timeout: .seconds(30))

        var responseHeaders: [HTTPHeader] = []
        for header in response.headers {
            responseHeaders.append(HTTPHeader(name: header.name, value: header.value))
        }

        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)

        return HTTPResponseMessage(
            requestID: request.requestID,
            statusCode: UInt16(response.status.code),
            headers: responseHeaders,
            body: Data(buffer: responseBody)
        )
    }

    private func handleConnectResponse(_ frame: ProtocolFrame) async throws {
        let response = try codec.decode(ConnectResponse.self, from: frame.payload)

        logger.info(
            "Tunnel connected successfully",
            metadata: [
                "tunnelID": "\(response.tunnelID.uuidString.prefix(8))",
                "subdomain": "\(response.subdomain)",
                "publicURL": "\(response.publicURL)",
            ])
    }

    private func handleError(_ frame: ProtocolFrame) async throws {
        let errorMsg = try codec.decode(ErrorMessage.self, from: frame.payload)

        logger.error(
            "Received error from server",
            metadata: [
                "code": "\(errorMsg.code)",
                "message": "\(errorMsg.message)",
            ])
    }

    private func handleHTTPResponse(_ frame: ProtocolFrame) async throws {
        let response = try codec.decode(HTTPResponseMessage.self, from: frame.payload)

        logger.debug(
            "Received response from tunnel",
            metadata: [
                "requestID": "\(response.requestID.uuidString.prefix(8))",
                "status": "\(response.statusCode)",
            ])

        if let continuation = pendingRequests.removeValue(forKey: response.requestID) {
            continuation.resume(returning: response)
        } else {
            logger.warning(
                "Received response for unknown request",
                metadata: [
                    "requestID": "\(response.requestID.uuidString.prefix(8))"
                ])
        }
    }

    private func convertToProtocolMessage(
        head: HTTPRequestHead,
        body: ByteBuffer,
        requestID: UUID
    ) -> HTTPRequestMessage {
        let headers = head.headers.map { HTTPHeader(name: $0.name, value: $0.value) }

        var bodyData = Data()
        if body.readableBytes > 0 {
            var buffer = body
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                bodyData = Data(bytes)
            }
        }

        return HTTPRequestMessage(
            requestID: requestID,
            method: head.method.rawValue,
            path: head.uri,
            headers: headers,
            body: bodyData,
            remoteAddress: "localhost"
        )
    }

    private func convertToHTTPResponse(_ message: HTTPResponseMessage) -> (
        HTTPResponseHead, ByteBuffer?
    ) {
        let status = HTTPResponseStatus(statusCode: Int(message.statusCode))
        var headers = HTTPHeaders()

        for header in message.headers {
            headers.add(name: header.name, value: header.value)
        }

        if !headers.contains(name: "Content-Length") {
            headers.add(name: "Content-Length", value: "\(message.body.count)")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        let body: ByteBuffer?
        if !message.body.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: message.body.count)
            buffer.writeBytes(message.body)
            body = buffer
        } else {
            body = nil
        }

        return (head, body)
    }

    public func pendingCount() -> Int {
        return pendingRequests.count
    }
}
