import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
import TunnelCore

public final class HTTPServer: Sendable {
    private let config: ServerConfig
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private let connectionManager: ConnectionManager
    private let requestTracker: RequestTracker
    private let rateLimiter: RateLimiter
    private let healthChecker: HealthChecker

    public init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        requestTracker: RequestTracker, rateLimiter: RateLimiter, healthChecker: HealthChecker
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
        self.healthChecker = healthChecker
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPRequestHandler(
                            config: self.config,
                            logger: self.logger,
                            connectionManager: self.connectionManager,
                            requestTracker: self.requestTracker,
                            rateLimiter: self.rateLimiter,
                            healthChecker: self.healthChecker
                        ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: config.httpPort).get()
        logger.info(
            "HTTP server listening",
            metadata: [
                "port": "\(config.httpPort)",
                "address": "\(channel.localAddress?.description ?? "unknown")",
            ])

        try await channel.closeFuture.get()
    }

    public func shutdown() async throws {
        try await group.shutdownGracefully()
    }
}

// @unchecked Sendable: `requestHead` and `requestBody` are mutable state that
// is strictly event loop confined — they are only ever accessed from `channelRead`,
// which NIO guarantees runs on the channel's dedicated event loop thread.
// The async `handleRequest` dispatch captures these values by copy before hopping
// off the event loop, so there is no concurrent access.
final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: ServerConfig
    private let logger: Logger
    private let connectionManager: ConnectionManager
    private let requestTracker: RequestTracker
    private let rateLimiter: RateLimiter
    private let healthChecker: HealthChecker
    private let converter: RequestConverter
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        requestTracker: RequestTracker, rateLimiter: RateLimiter, healthChecker: HealthChecker
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
        self.healthChecker = healthChecker
        self.converter = RequestConverter()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            requestBody?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }

            let body = requestBody ?? ByteBuffer()
            nonisolated(unsafe) let ctx = context
            let eventLoop = context.eventLoop
            let handler = self
            Task { @Sendable in
                await handler.handleRequest(
                    context: ctx, eventLoop: eventLoop, head: head, body: body)
            }
            requestHead = nil
            requestBody = nil
        }
    }

    private func handleRequest(
        context: ChannelHandlerContext, eventLoop: EventLoop, head: HTTPRequestHead,
        body: ByteBuffer
    ) async {
        if config.healthCheckPaths.contains(head.uri) {
            let report = await healthChecker.runChecks()
            let httpStatus: HTTPResponseStatus =
                report.status == .healthy ? .ok : .serviceUnavailable
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report),
                let json = String(data: data, encoding: .utf8)
            {
                sendResponse(
                    context: context, eventLoop: eventLoop,
                    status: httpStatus, body: json, contentType: "application/json")
            } else {
                sendResponse(
                    context: context, eventLoop: eventLoop,
                    status: httpStatus, body: report.status.rawValue)
            }
            return
        }

        let clientIP = context.remoteAddress?.ipAddress ?? "unknown"

        guard await rateLimiter.tryConsume(identifier: clientIP) else {
            sendResponse(
                context: context, eventLoop: eventLoop, status: .tooManyRequests,
                body: "Rate limit exceeded")
            return
        }

        do {
            try RequestSizeValidator.validateBodySize(body.readableBytes)
            try RequestSizeValidator.validatePath(head.uri)
        } catch let error as RequestSizeValidator.ValidationError {
            sendResponse(
                context: context, eventLoop: eventLoop, status: .payloadTooLarge,
                body: error.message)
            return
        } catch {
            sendResponse(
                context: context, eventLoop: eventLoop, status: .badRequest, body: "Invalid request"
            )
            return
        }

        let subdomain = extractSubdomain(from: head.headers["host"].first ?? "")

        let safeURI = (try? InputSanitizer.sanitizeString(head.uri)) ?? "invalid-uri"
        let safeSubdomain =
            (try? InputSanitizer.sanitizeString(subdomain ?? "none")) ?? "invalid-subdomain"

        logger.debug(
            "HTTP request received",
            metadata: [
                "method": "\(head.method)",
                "uri": "\(safeURI)",
                "subdomain": "\(safeSubdomain)",
            ])

        guard let subdomain = subdomain else {
            sendResponse(
                context: context, eventLoop: eventLoop, status: .notFound, body: "Invalid host")
            return
        }

        guard let tunnel = await connectionManager.getTunnel(forSubdomain: subdomain) else {
            // Safe to log subdomain here since we sanitized it for the debug log above,
            // but let's be safe and use safeSubdomain again if we wanted,
            // but for the metadata value in info log:
            let safeLogSubdomain =
                (try? InputSanitizer.sanitizeString(subdomain)) ?? "invalid-subdomain"
            sendResponse(
                context: context, eventLoop: eventLoop, status: .notFound,
                body: "Tunnel not found: \(safeLogSubdomain)")
            return
        }

        let safeTunnelID = (try? InputSanitizer.sanitizeString(tunnel.id.uuidString)) ?? "unknown"
        logger.info(
            "Routing request to tunnel",
            metadata: [
                "subdomain": "\(safeSubdomain)",  // safeSubdomain was calculated above
                "tunnelID": "\(safeTunnelID.prefix(8))",
            ])

        await forwardToTunnel(
            context: context,
            eventLoop: eventLoop,
            head: head,
            body: body,
            tunnel: tunnel
        )
    }

    private func forwardToTunnel(
        context: ChannelHandlerContext,
        eventLoop: EventLoop,
        head: HTTPRequestHead,
        body: ByteBuffer,
        tunnel: TunnelConnection
    ) async {
        do {
            let remoteAddress = context.remoteAddress?.description ?? "unknown"
            let protocolRequest = converter.toProtocolMessage(
                head: head, body: body, remoteAddress: remoteAddress)

            // Start tracking before sending so the response can't arrive before
            // we're listening. async let suspends lazily — the actual await happens
            // after sendRequest, which is the correct ordering.
            async let trackedResponse = requestTracker.track(requestID: protocolRequest.requestID)

            try await connectionManager.sendRequest(
                tunnelID: tunnel.id, request: protocolRequest)

            let response = try await trackedResponse

            let (responseHead, responseBody) = converter.toHTTPResponse(message: response)

            nonisolated(unsafe) let ctx = context
            let wrapOut = self.wrapOutboundOut
            eventLoop.execute {
                ctx.write(wrapOut(.head(responseHead)), promise: nil)

                if let body = responseBody {
                    ctx.write(wrapOut(.body(.byteBuffer(body))), promise: nil)
                }

                ctx.writeAndFlush(wrapOut(.end(nil))).whenComplete { _ in
                    ctx.close(promise: nil)
                }
            }

            logger.info(
                "Request completed",
                metadata: [
                    "requestID": "\(protocolRequest.requestID.uuidString.prefix(8))",
                    "status": "\(response.statusCode)",
                ])

        } catch let error as TunnelError {
            handleTunnelError(context: context, eventLoop: eventLoop, error: error)
        } catch {
            logger.error(
                "Request forwarding failed",
                metadata: [
                    "error": "\(error.localizedDescription)"
                ])
            sendResponse(
                context: context, eventLoop: eventLoop, status: .internalServerError,
                body: "Internal server error")
        }
    }

    private func handleTunnelError(
        context: ChannelHandlerContext, eventLoop: EventLoop, error: TunnelError
    ) {
        switch error {
        case .client(.timeout, _):
            sendResponse(
                context: context, eventLoop: eventLoop, status: .gatewayTimeout,
                body: "Gateway timeout")

        case .server(.tunnelNotFound, _):
            sendResponse(
                context: context, eventLoop: eventLoop, status: .serviceUnavailable,
                body: "Tunnel disconnected")

        case .client(let clientError, _):
            let status = HTTPResponseStatus(statusCode: 400)
            sendResponse(
                context: context, eventLoop: eventLoop, status: status,
                body: "Client error: \(clientError)")

        default:
            sendResponse(
                context: context, eventLoop: eventLoop, status: .badGateway, body: "Bad gateway")
        }
    }

    /// Extracts the subdomain from a `Host` header value, validating that the
    /// host ends with `.{baseDomain}`. Returns `nil` for any host that doesn't
    /// match, preventing arbitrary `Host` headers from triggering tunnel lookups.
    private func extractSubdomain(from host: String) -> String? {
        // Strip port if present (e.g. "foo.example.com:8080" → "foo.example.com")
        let hostWithoutPort =
            host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        let suffix = ".\(config.baseDomain)"
        guard hostWithoutPort.hasSuffix(suffix) else { return nil }
        let subdomain = String(hostWithoutPort.dropLast(suffix.count))
        return subdomain.isEmpty ? nil : subdomain
    }

    private func sendResponse(
        context: ChannelHandlerContext, eventLoop: EventLoop, status: HTTPResponseStatus,
        body: String, contentType: String = "text/plain; charset=utf-8"
    ) {
        nonisolated(unsafe) let ctx = context
        let wrapOut = self.wrapOutboundOut
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(body.utf8.count)")
            headers.add(name: "Connection", value: "close")

            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            ctx.write(wrapOut(.head(head)), promise: nil)

            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            ctx.write(wrapOut(.body(.byteBuffer(buffer))), promise: nil)

            ctx.writeAndFlush(wrapOut(.end(nil))).whenComplete { _ in
                ctx.close(promise: nil)
            }
        }
    }
}
