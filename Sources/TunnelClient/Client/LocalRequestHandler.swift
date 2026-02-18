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

    // MARK: - Incoming Frame Dispatch

    public func handleIncomingMessage(_ frame: ProtocolFrame) {
        Task {
            do {
                switch frame.messageType {
                case .connectResponse:
                    try await handleConnectResponse(frame)
                case .httpRequest:
                    try await handleHTTPRequest(frame)
                case .pong:
                    logger.debug("Received pong from server")
                case .error:
                    try await handleError(frame)
                default:
                    logger.warning(
                        "Unexpected message type",
                        metadata: ["type": "\(frame.messageType)"]
                    )
                }
            } catch {
                logger.error(
                    "Error handling incoming message",
                    metadata: ["error": "\(error.localizedDescription)"]
                )
            }
        }
    }

    // MARK: - Frame Handlers

    private func handleHTTPRequest(_ frame: ProtocolFrame) async throws {
        let request = try codec.decode(HTTPRequestMessage.self, from: frame.payload)

        let safeRequestID =
            (try? InputSanitizer.sanitizeString(request.requestID.uuidString)) ?? "unknown"
        let safeMethod = (try? InputSanitizer.sanitizeString(request.method)) ?? "unknown-method"
        let safePath = (try? InputSanitizer.sanitizePath(request.path)) ?? "invalid-path"

        logger.debug(
            "Received request from tunnel",
            metadata: [
                "requestID": "\(safeRequestID.prefix(8))",
                "method": "\(safeMethod)",
                "path": "\(safePath)",
            ]
        )

        guard await circuitBreaker.canAttempt() else {
            logger.warning(
                "Circuit breaker open, returning 503 for request \(safeRequestID.prefix(8))")
            try await sendErrorResponse(
                requestID: request.requestID, statusCode: 503, message: "Service Unavailable")
            await circuitBreaker.recordFailure()
            return
        }

        do {
            let response = try await forwardToLocalServer(request)
            await circuitBreaker.recordSuccess()

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
                    "requestID": "\(safeRequestID.prefix(8))",
                    "status": "\(response.statusCode)",
                ]
            )
        } catch {
            await circuitBreaker.recordFailure()

            let safeError =
                (try? InputSanitizer.sanitizeString(error.localizedDescription)) ?? "unknown-error"
            logger.error(
                "Failed to forward request to local server",
                metadata: [
                    "requestID": "\(safeRequestID.prefix(8))",
                    "error": "\(safeError)",
                ]
            )

            try await sendErrorResponse(
                requestID: request.requestID, statusCode: 502,
                message: "Bad Gateway: Failed to reach local server")
        }
    }

    private func handleConnectResponse(_ frame: ProtocolFrame) async throws {
        let response = try codec.decode(ConnectResponse.self, from: frame.payload)

        logger.info(
            "Tunnel connected successfully",
            metadata: [
                "tunnelID": "\(response.tunnelID.uuidString.prefix(8))",
                "subdomain": "\(response.subdomain)",
                "publicURL": "\(response.publicURL)",
            ]
        )
    }

    private func handleError(_ frame: ProtocolFrame) async throws {
        let errorMsg = try codec.decode(ErrorMessage.self, from: frame.payload)

        logger.error(
            "Received error from server",
            metadata: [
                "code": "\(errorMsg.code)",
                "message": "\(errorMsg.message)",
            ]
        )
    }

    // MARK: - Local Server Forwarding

    private func forwardToLocalServer(
        _ request: HTTPRequestMessage
    ) async throws -> HTTPResponseMessage {
        let urlString = "http://\(config.localHost):\(config.localPort)\(request.path)"

        var httpRequest = HTTPClientRequest(url: urlString)
        httpRequest.method = HTTPMethod(rawValue: request.method)

        for header in request.headers {
            httpRequest.headers.add(name: header.name, value: header.value)
        }

        if request.body.readableBytes > 0 {
            httpRequest.body = .bytes(request.body.readableBytesView)
        }

        let response = try await httpClient.execute(httpRequest, timeout: .seconds(30))

        let responseHeaders = response.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
        let responseBody = try await response.body.collect(upTo: Int(ProtocolFrame.maxPayloadSize))

        return HTTPResponseMessage(
            requestID: request.requestID,
            statusCode: UInt16(response.status.code),
            headers: responseHeaders,
            body: responseBody
        )
    }

    // MARK: - Helpers

    private func sendErrorResponse(requestID: UUID, statusCode: UInt16, message: String)
        async throws
    {
        let errorResponse = HTTPResponseMessage(
            requestID: requestID,
            statusCode: statusCode,
            headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
            body: ByteBuffer(string: message)
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
