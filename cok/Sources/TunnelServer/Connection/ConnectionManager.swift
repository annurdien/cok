import Foundation
import Logging
import NIOCore
import NIOWebSocket
import TunnelCore

public struct TunnelConnection: Sendable {
    public let id: UUID
    public let subdomain: String
    public let apiKey: String
    public let connectedAt: Date
    public let channel: Channel

    public init(
        id: UUID = UUID(), subdomain: String, apiKey: String, connectedAt: Date = Date(),
        channel: Channel
    ) {
        self.id = id
        self.subdomain = subdomain
        self.apiKey = apiKey
        self.connectedAt = connectedAt
        self.channel = channel
    }
}

public actor ConnectionManager {
    private var tunnels: [String: TunnelConnection] = [:]
    private var subdomainToTunnel: [String: UUID] = [:]
    private let maxConnections: Int
    private let logger: Logger
    private let codec: MessageCodec

    public init(maxConnections: Int, logger: Logger, codec: MessageCodec = JSONMessageCodec()) {
        self.maxConnections = maxConnections
        self.logger = logger
        self.codec = codec
    }

    public func registerTunnel(subdomain: String, apiKey: String, channel: Channel) throws
        -> TunnelConnection
    {
        guard !subdomain.isEmpty else {
            throw ServerError.internalError("Subdomain cannot be empty")
        }

        guard tunnels.count < maxConnections else {
            throw ServerError.serviceUnavailable
        }

        if subdomainToTunnel[subdomain] != nil {
            throw ServerError.subdomainTaken
        }

        let tunnel = TunnelConnection(
            subdomain: subdomain, apiKey: apiKey, channel: channel)
        tunnels[tunnel.id.uuidString] = tunnel
        subdomainToTunnel[subdomain] = tunnel.id

        logger.info(
            "Tunnel registered",
            metadata: [
                "tunnelID": "\(tunnel.id.uuidString.prefix(8))",
                "subdomain": "\(subdomain)",
            ])

        return tunnel
    }

    public func sendRequest(tunnelID: UUID, request: HTTPRequestMessage) async throws {
        guard let tunnel = tunnels[tunnelID.uuidString] else {
            throw TunnelError.server(
                .tunnelNotFound(tunnelID),
                context: ErrorContext(
                    component: "ConnectionManager",
                    metadata: ["tunnelID": tunnelID.uuidString]
                ))
        }

        let payload = try codec.encode(request)
        let frame = try ProtocolFrame(
            version: .current,
            messageType: .httpRequest,
            flags: [],
            payload: payload
        )

        let frameData = try frame.encode()

        let wsFrame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            data: frameData
        )

        try await tunnel.channel.writeAndFlush(wsFrame).get()

        logger.debug(
            "Sent request to tunnel",
            metadata: [
                "tunnelID": "\(tunnelID.uuidString.prefix(8))",
                "requestID": "\(request.requestID.uuidString.prefix(8))",
            ])
    }

    public func unregisterTunnel(id: UUID) {
        guard let tunnel = tunnels.removeValue(forKey: id.uuidString) else {
            return
        }

        subdomainToTunnel.removeValue(forKey: tunnel.subdomain)

        logger.info(
            "Tunnel unregistered",
            metadata: [
                "tunnelID": "\(id.uuidString.prefix(8))",
                "subdomain": "\(tunnel.subdomain)",
            ])
    }

    public func getTunnel(forSubdomain subdomain: String) -> TunnelConnection? {
        guard let tunnelID = subdomainToTunnel[subdomain] else {
            return nil
        }
        return tunnels[tunnelID.uuidString]
    }

    public func getTunnel(byID id: UUID) -> TunnelConnection? {
        return tunnels[id.uuidString]
    }

    public func listTunnels() -> [TunnelConnection] {
        return Array(tunnels.values)
    }

    public func connectionCount() -> Int {
        return tunnels.count
    }

    public func disconnectAll() async {
        let tunnelList = Array(tunnels.values)
        for tunnel in tunnelList {
            tunnel.channel.close(promise: nil)
            unregisterTunnel(id: tunnel.id)
        }
        logger.info("All tunnels disconnected", metadata: ["count": "\(tunnelList.count)"])
    }
}
