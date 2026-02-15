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

    public init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        requestTracker: RequestTracker, rateLimiter: RateLimiter
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
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
                            rateLimiter: self.rateLimiter
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

final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: ServerConfig
    private let logger: Logger
    private let connectionManager: ConnectionManager
    private let requestTracker: RequestTracker
    private let rateLimiter: RateLimiter
    private let converter: RequestConverter
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(
        config: ServerConfig, logger: Logger, connectionManager: ConnectionManager,
        requestTracker: RequestTracker, rateLimiter: RateLimiter
    ) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
        self.requestTracker = requestTracker
        self.rateLimiter = rateLimiter
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
                await handler.handleRequest(context: ctx, eventLoop: eventLoop, head: head, body: body)
            }
            requestHead = nil
            requestBody = nil
        }
    }

    private func handleRequest(
        context: ChannelHandlerContext, eventLoop: EventLoop, head: HTTPRequestHead, body: ByteBuffer
    ) async {
        if head.uri == "/health" || head.uri == "/health/live" || head.uri == "/health/ready" {
            sendResponse(context: context, eventLoop: eventLoop, status: .ok, body: "OK")
            return
        }

        let clientIP = context.remoteAddress?.ipAddress ?? "unknown"

        guard await rateLimiter.tryConsume(identifier: clientIP) else {
            sendResponse(context: context, eventLoop: eventLoop, status: .tooManyRequests, body: "Rate limit exceeded")
            return
        }

        do {
            try RequestSizeValidator.validateBodySize(body.readableBytes)
            try RequestSizeValidator.validatePath(head.uri)
        } catch let error as RequestSizeValidator.ValidationError {
            sendResponse(context: context, eventLoop: eventLoop, status: .payloadTooLarge, body: error.message)
            return
        } catch {
            sendResponse(context: context, eventLoop: eventLoop, status: .badRequest, body: "Invalid request")
            return
        }

        let subdomain = extractSubdomain(from: head.headers["host"].first ?? "")

        logger.debug(
            "HTTP request received",
            metadata: [
                "method": "\(head.method)",
                "uri": "\(head.uri)",
                "subdomain": "\(subdomain ?? "none")",
            ])

        guard let subdomain = subdomain else {
            sendResponse(context: context, eventLoop: eventLoop, status: .notFound, body: "Invalid host")
            return
        }

        guard let tunnel = await connectionManager.getTunnel(forSubdomain: subdomain) else {
            sendResponse(
                context: context, eventLoop: eventLoop, status: .notFound, body: "Tunnel not found: \(subdomain)")
            return
        }

        logger.info(
            "Routing request to tunnel",
            metadata: [
                "subdomain": "\(subdomain)",
                "tunnelID": "\(tunnel.id.uuidString.prefix(8))",
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

            let responsePromise = Task {
                try await requestTracker.track(requestID: protocolRequest.requestID)
            }

            try await connectionManager.sendRequest(
                tunnelID: tunnel.id, request: protocolRequest)

            let response = try await responsePromise.value

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

    private func handleTunnelError(context: ChannelHandlerContext, eventLoop: EventLoop, error: TunnelError) {
        switch error {
        case .client(.timeout, _):
            sendResponse(context: context, eventLoop: eventLoop, status: .gatewayTimeout, body: "Gateway timeout")

        case .server(.tunnelNotFound, _):
            sendResponse(
                context: context, eventLoop: eventLoop, status: .serviceUnavailable, body: "Tunnel disconnected")

        case .client(let clientError, _):
            let status = HTTPResponseStatus(statusCode: 400)
            sendResponse(
                context: context, eventLoop: eventLoop, status: status, body: "Client error: \(clientError)")

        default:
            sendResponse(context: context, eventLoop: eventLoop, status: .badGateway, body: "Bad gateway")
        }
    }

    private func extractSubdomain(from host: String) -> String? {
        guard let firstComponent = host.split(separator: ".").first else {
            return nil
        }
        return String(firstComponent)
    }

    private func sendResponse(
        context: ChannelHandlerContext, eventLoop: EventLoop, status: HTTPResponseStatus, body: String
    ) {
        nonisolated(unsafe) let ctx = context
        let wrapOut = self.wrapOutboundOut
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
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
