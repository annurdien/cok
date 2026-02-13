import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public final class HTTPServer: Sendable {
    private let config: ServerConfig
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private let connectionManager: ConnectionManager

    public init(config: ServerConfig, logger: Logger, connectionManager: ConnectionManager) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
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
                            connectionManager: self.connectionManager
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
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(config: ServerConfig, logger: Logger, connectionManager: ConnectionManager) {
        self.config = config
        self.logger = logger
        self.connectionManager = connectionManager
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

            Task {
                await handleRequest(context: context, head: head, body: requestBody ?? ByteBuffer())
            }
            requestHead = nil
            requestBody = nil
        }
    }

    private func handleRequest(
        context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer
    ) async {
        let subdomain = extractSubdomain(from: head.headers["host"].first ?? "")

        logger.debug(
            "HTTP request received",
            metadata: [
                "method": "\(head.method)",
                "uri": "\(head.uri)",
                "subdomain": "\(subdomain ?? "none")",
            ])

        guard let subdomain = subdomain else {
            sendResponse(context: context, status: .notFound, body: "Invalid host")
            return
        }

        guard let tunnel = await connectionManager.getTunnel(forSubdomain: subdomain) else {
            sendResponse(
                context: context, status: .notFound, body: "Tunnel not found: \(subdomain)")
            return
        }

        logger.info(
            "Routing request",
            metadata: [
                "subdomain": "\(subdomain)",
                "tunnelID": "\(tunnel.id.uuidString.prefix(8))",
            ])

        sendResponse(context: context, status: .ok, body: "Request forwarding - coming soon")
    }

    private func extractSubdomain(from host: String) -> String? {
        guard let firstComponent = host.split(separator: ".").first else {
            return nil
        }
        return String(firstComponent)
    }

    private func sendResponse(
        context: ChannelHandlerContext, status: HTTPResponseStatus, body: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
