import Foundation
import Logging
import NIOCore
import TunnelCore

public struct TunnelConnection: Sendable {
    public let id: UUID
    public let subdomain: String
    public let apiKey: String
    public let connectedAt: Date

    public init(id: UUID = UUID(), subdomain: String, apiKey: String, connectedAt: Date = Date()) {
        self.id = id
        self.subdomain = subdomain
        self.apiKey = apiKey
        self.connectedAt = connectedAt
    }
}

public actor ConnectionManager {
    private var tunnels: [String: TunnelConnection] = [:]
    private var subdomainToTunnel: [String: UUID] = [:]
    private let maxConnections: Int
    private let logger: Logger

    public init(maxConnections: Int, logger: Logger) {
        self.maxConnections = maxConnections
        self.logger = logger
    }

    public func registerTunnel(subdomain: String, apiKey: String) throws -> TunnelConnection {
        guard tunnels.count < maxConnections else {
            throw ServerError.serviceUnavailable
        }

        if subdomainToTunnel[subdomain] != nil {
            throw ServerError.subdomainTaken
        }

        let tunnel = TunnelConnection(subdomain: subdomain, apiKey: apiKey)
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
}
