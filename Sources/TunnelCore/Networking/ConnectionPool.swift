import NIOCore
import NIOPosix
import Foundation

public actor ConnectionPool {
    public struct Configuration: Sendable {
        public let maxConnections: Int
        public let maxIdleTime: TimeInterval
        public let connectionTimeout: TimeInterval
        
        public init(maxConnections: Int = 100, maxIdleTime: TimeInterval = 60, connectionTimeout: TimeInterval = 10) {
            self.maxConnections = maxConnections
            self.maxIdleTime = maxIdleTime
            self.connectionTimeout = connectionTimeout
        }
    }
    
    private struct PooledConnection: Sendable {
        let channel: Channel
        let createdAt: Date
        var lastUsed: Date
        
        var isIdle: Bool { Date().timeIntervalSince(lastUsed) > 0 }
        
        func isExpired(maxIdleTime: TimeInterval) -> Bool {
            Date().timeIntervalSince(lastUsed) > maxIdleTime
        }
    }
    
    private let config: Configuration
    private let eventLoopGroup: EventLoopGroup
    private var connections: [String: [PooledConnection]] = [:]
    private var activeCount: Int = 0
    
    public init(configuration: Configuration, eventLoopGroup: EventLoopGroup) {
        self.config = configuration
        self.eventLoopGroup = eventLoopGroup
    }
    
    public func acquire(host: String, port: Int) async throws -> Channel {
        let key = "\(host):\(port)"
        
        if var hostConnections = connections[key], !hostConnections.isEmpty {
            var conn = hostConnections.removeFirst()
            if hostConnections.isEmpty {
                connections.removeValue(forKey: key)
            } else {
                connections[key] = hostConnections
            }
            
            if conn.channel.isActive {
                conn.lastUsed = Date()
                activeCount += 1
                return conn.channel
            }
        }
        
        guard activeCount < config.maxConnections else {
            throw ConnectionPoolError.poolExhausted
        }
        
        let channel = try await createConnection(host: host, port: port)
        activeCount += 1
        return channel
    }
    
    public func release(channel: Channel, host: String, port: Int) {
        let key = "\(host):\(port)"
        activeCount = max(0, activeCount - 1)
        
        guard channel.isActive else { return }
        
        let pooled = PooledConnection(channel: channel, createdAt: Date(), lastUsed: Date())
        var hostConnections = connections[key] ?? []
        hostConnections.append(pooled)
        connections[key] = hostConnections
    }
    
    public func evictExpired() {
        let now = Date()
        for (key, pooledConns) in connections {
            let valid = pooledConns.filter { !$0.isExpired(maxIdleTime: config.maxIdleTime) && $0.channel.isActive }
            if valid.isEmpty {
                connections.removeValue(forKey: key)
            } else {
                connections[key] = valid
            }
        }
    }
    
    public func closeAll() async {
        for (_, pooledConns) in connections {
            for conn in pooledConns {
                try? await conn.channel.close()
            }
        }
        connections.removeAll()
        activeCount = 0
    }
    
    public var statistics: (active: Int, pooled: Int) {
        let pooled = connections.values.reduce(0) { $0 + $1.count }
        return (activeCount, pooled)
    }
    
    private func createConnection(host: String, port: Int) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(Int64(config.connectionTimeout)))
        
        return try await bootstrap.connect(host: host, port: port).get()
    }
}

public enum ConnectionPoolError: Error, Sendable {
    case poolExhausted
    case connectionFailed(String)
    case timeout
}
