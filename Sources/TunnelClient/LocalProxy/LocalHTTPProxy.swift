import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
import TunnelCore

public final class LocalHTTPProxy: @unchecked Sendable {
    private let config: ClientConfig
    private let logger: Logger
    private let requestHandler: LocalRequestHandler
    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup

    public init(config: ClientConfig, requestHandler: LocalRequestHandler, logger: Logger) {
        self.config = config
        self.requestHandler = requestHandler
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(requestHandler: self.requestHandler, logger: self.logger))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        self.channel = try await bootstrap.bind(host: config.localHost, port: config.localPort).get()

        logger.info("Local HTTP proxy started", metadata: [
            "host": "\(config.localHost)",
            "port": "\(config.localPort)"
        ])
    }

    public func stop() async throws {
        if let channel = channel {
            try await channel.close().get()
            self.channel = nil
        }

        try await group.shutdownGracefully()

        logger.info("Local HTTP proxy stopped")
    }
}

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let requestHandler: LocalRequestHandler
    private let logger: Logger
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(requestHandler: LocalRequestHandler, logger: Logger) {
        self.requestHandler = requestHandler
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            self.requestBody?.writeBuffer(&buffer)

        case .end:
            guard let head = self.requestHead else {
                sendError(context: context, status: .badRequest)
                return
            }

            let body = self.requestBody ?? context.channel.allocator.buffer(capacity: 0)

            let eventLoop = context.eventLoop
            let handler = self.requestHandler
            let logger = self.logger
            let wrapOutbound = self.wrapOutboundOut
            nonisolated(unsafe) let ctx = context

            _ = Task.detached { @Sendable in
                do {
                    let (responseHead, responseBody) = try await handler.handleRequest(head: head, body: body)

                    eventLoop.execute {
                        ctx.write(wrapOutbound(.head(responseHead)), promise: nil)

                        if let body = responseBody {
                            ctx.write(wrapOutbound(.body(.byteBuffer(body))), promise: nil)
                        }

                        ctx.writeAndFlush(wrapOutbound(.end(nil)), promise: nil)
                    }
                } catch {
                    logger.error("Request handling failed", metadata: [
                        "error": "\(error.localizedDescription)"
                    ])

                    eventLoop.execute {
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Length", value: "0")
                        headers.add(name: "Connection", value: "close")
                        let head = HTTPResponseHead(version: .http1_1, status: .internalServerError, headers: headers)
                        ctx.write(wrapOutbound(.head(head)), promise: nil)
                        ctx.writeAndFlush(wrapOutbound(.end(nil))).whenComplete { _ in
                            ctx.close(promise: nil)
                        }
                    }
                }
            }

            self.requestHead = nil
            self.requestBody = nil
        }
    }

    private nonisolated func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        nonisolated(unsafe) let ctx = context
        let wrapOut = self.wrapOutboundOut
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            headers.add(name: "Connection", value: "close")

            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

            ctx.write(wrapOut(.head(head)), promise: nil)
            ctx.writeAndFlush(wrapOut(.end(nil))).whenComplete { _ in
                ctx.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error", metadata: [
            "error": "\(error.localizedDescription)"
        ])

        context.close(promise: nil)
    }
}
