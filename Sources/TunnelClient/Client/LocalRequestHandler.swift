import Foundation
import Logging
import NIOCore
import NIOHTTP1
import TunnelCore

public actor LocalRequestHandler {
    private let websocketClient: TunnelWebSocketClient
    private let circuitBreaker: CircuitBreaker
    private let logger: Logger
    private let config: ClientConfig
    private var pendingRequests: [UUID: CheckedContinuation<HTTPResponseMessage, Error>] = [:]

    public init(
        websocketClient: TunnelWebSocketClient,
        circuitBreaker: CircuitBreaker,
        config: ClientConfig,
        logger: Logger
    ) {
        self.websocketClient = websocketClient
        self.circuitBreaker = circuitBreaker
        self.config = config
        self.logger = logger
    }

    public func handleRequest(head: HTTPRequestHead, body: ByteBuffer) async throws -> (HTTPResponseHead, ByteBuffer?) {
        guard await circuitBreaker.canAttempt() else {
            logger.warning("Circuit breaker is open, rejecting request")
            throw TunnelError.client(.localServerUnreachable(host: config.localHost, port: config.localPort), context: ErrorContext(component: "RequestHandler"))
        }

        guard await websocketClient.isConnected() else {
            await circuitBreaker.recordFailure()
            throw TunnelError.client(.connectionFailed("Not connected to tunnel server"), context: ErrorContext(component: "RequestHandler"))
        }

        let requestID = UUID()
        let requestMessage = convertToProtocolMessage(head: head, body: body, requestID: requestID)

        do {
            let response = try await sendAndWaitForResponse(requestID: requestID, request: requestMessage)
            await circuitBreaker.recordSuccess()
            return convertToHTTPResponse(response)
        } catch {
            await circuitBreaker.recordFailure()
            throw error
        }
    }

    private func sendAndWaitForResponse(requestID: UUID, request: HTTPRequestMessage) async throws -> HTTPResponseMessage {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        await self.storeContinuation(requestID: requestID, continuation: continuation)

                        let payload = try JSONEncoder().encode(request)
                        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
                        buffer.writeBytes(payload)

                        let frame = try ProtocolFrame(
                            version: .current,
                            messageType: .httpResponse,
                            flags: [],
                            payload: buffer
                        )

                        try await self.websocketClient.sendFrame(frame)

                        self.logger.debug("Sent request to tunnel", metadata: [
                            "requestID": "\(requestID.uuidString.prefix(8))",
                            "method": "\(request.method)",
                            "path": "\(request.path)"
                        ])

                        Task {
                            try await Task.sleep(for: .seconds(self.config.requestTimeout))

                            if let storedContinuation = await self.removeContinuation(requestID: requestID) {
                                self.logger.warning("Request timeout", metadata: [
                                    "requestID": "\(requestID.uuidString.prefix(8))"
                                ])

                                storedContinuation.resume(throwing: TunnelError.client(.timeout, context: ErrorContext(component: "RequestHandler")))
                            }
                        }
                    } catch {
                        await self.removeContinuation(requestID: requestID)
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

    private func storeContinuation(requestID: UUID, continuation: CheckedContinuation<HTTPResponseMessage, Error>) {
        pendingRequests[requestID] = continuation
    }

    private func removeContinuation(requestID: UUID) -> CheckedContinuation<HTTPResponseMessage, Error>? {
        return pendingRequests.removeValue(forKey: requestID)
    }

    private func cancelRequest(requestID: UUID) {
        if let continuation = pendingRequests.removeValue(forKey: requestID) {
            logger.debug("Request cancelled", metadata: [
                "requestID": "\(requestID.uuidString.prefix(8))"
            ])

            continuation.resume(throwing: CancellationError())
        }
    }

    public func handleIncomingMessage(_ frame: ProtocolFrame) {
        Task {
            do {
                switch frame.messageType {
                case .httpRequest:
                    try await handleHTTPRequest(frame)
                case .httpResponse:
                    try await handleHTTPResponse(frame)
                case .pong:
                    logger.debug("Received pong from server")
                default:
                    logger.warning("Unexpected message type", metadata: [
                        "type": "\(frame.messageType)"
                    ])
                }
            } catch {
                logger.error("Error handling incoming message", metadata: [
                    "error": "\(error.localizedDescription)"
                ])
            }
        }
    }

    private func handleHTTPRequest(_ frame: ProtocolFrame) async throws {
        var buffer = frame.payload
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            throw ProtocolError.decodingFailed(reason: "Failed to read payload bytes")
        }

        let data = Data(bytes)
        let request = try JSONDecoder().decode(HTTPRequestMessage.self, from: data)

        logger.debug("Received request from tunnel", metadata: [
            "requestID": "\(request.requestID.uuidString.prefix(8))",
            "method": "\(request.method)",
            "path": "\(request.path)"
        ])

        if let continuation = pendingRequests.removeValue(forKey: request.requestID) {
            let response = HTTPResponseMessage(
                requestID: request.requestID,
                statusCode: 200,
                headers: [],
                body: Data()
            )
            continuation.resume(returning: response)
        }
    }

    private func handleHTTPResponse(_ frame: ProtocolFrame) async throws {
        var buffer = frame.payload
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            throw ProtocolError.decodingFailed(reason: "Failed to read payload bytes")
        }

        let data = Data(bytes)
        let response = try JSONDecoder().decode(HTTPResponseMessage.self, from: data)

        logger.debug("Received response from tunnel", metadata: [
            "requestID": "\(response.requestID.uuidString.prefix(8))",
            "status": "\(response.statusCode)"
        ])

        if let continuation = pendingRequests.removeValue(forKey: response.requestID) {
            continuation.resume(returning: response)
        } else {
            logger.warning("Received response for unknown request", metadata: [
                "requestID": "\(response.requestID.uuidString.prefix(8))"
            ])
        }
    }

    private func convertToProtocolMessage(head: HTTPRequestHead, body: ByteBuffer, requestID: UUID) -> HTTPRequestMessage {
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
            remoteAddress: "127.0.0.1"
        )
    }

    private func convertToHTTPResponse(_ message: HTTPResponseMessage) -> (HTTPResponseHead, ByteBuffer?) {
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
        if message.body.count > 0 {
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
