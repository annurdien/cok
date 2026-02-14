import Foundation

public struct ClientConfig: Sendable {
    public let serverURL: String
    public let subdomain: String
    public let apiKey: String
    public let localHost: String
    public let localPort: Int
    public let reconnectDelay: TimeInterval
    public let maxReconnectAttempts: Int
    public let requestTimeout: TimeInterval
    public let healthCheckInterval: TimeInterval
    public let circuitBreakerThreshold: Int
    public let circuitBreakerTimeout: TimeInterval

    public init(
        serverURL: String,
        subdomain: String,
        apiKey: String,
        localHost: String = "localhost",
        localPort: Int = 3000,
        reconnectDelay: TimeInterval = 5.0,
        maxReconnectAttempts: Int = -1,
        requestTimeout: TimeInterval = 30.0,
        healthCheckInterval: TimeInterval = 30.0,
        circuitBreakerThreshold: Int = 5,
        circuitBreakerTimeout: TimeInterval = 60.0
    ) {
        self.serverURL = serverURL
        self.subdomain = subdomain
        self.apiKey = apiKey
        self.localHost = localHost
        self.localPort = localPort
        self.reconnectDelay = reconnectDelay
        self.maxReconnectAttempts = maxReconnectAttempts
        self.requestTimeout = requestTimeout
        self.healthCheckInterval = healthCheckInterval
        self.circuitBreakerThreshold = circuitBreakerThreshold
        self.circuitBreakerTimeout = circuitBreakerTimeout
    }

    public static func fromEnvironment() throws -> ClientConfig {
        guard let serverURL = ProcessInfo.processInfo.environment["COK_SERVER_URL"] else {
            throw ConfigError.missingRequired("COK_SERVER_URL")
        }

        guard let subdomain = ProcessInfo.processInfo.environment["COK_SUBDOMAIN"] else {
            throw ConfigError.missingRequired("COK_SUBDOMAIN")
        }

        guard let apiKey = ProcessInfo.processInfo.environment["COK_API_KEY"] else {
            throw ConfigError.missingRequired("COK_API_KEY")
        }

        let localHost = ProcessInfo.processInfo.environment["COK_LOCAL_HOST"] ?? "localhost"
        let localPort = Int(ProcessInfo.processInfo.environment["COK_LOCAL_PORT"] ?? "3000") ?? 3000

        return ClientConfig(
            serverURL: serverURL,
            subdomain: subdomain,
            apiKey: apiKey,
            localHost: localHost,
            localPort: localPort
        )
    }

    public func validate() throws {
        guard let url = URL(string: serverURL), url.scheme == "wss" || url.scheme == "ws" else {
            throw ConfigError.invalidURL(serverURL)
        }

        guard !subdomain.isEmpty, subdomain.count <= 63 else {
            throw ConfigError.invalidSubdomain(subdomain)
        }

        guard !apiKey.isEmpty else {
            throw ConfigError.invalidAPIKey
        }

        guard localPort > 0, localPort <= 65535 else {
            throw ConfigError.invalidPort(localPort)
        }

        guard !localHost.isEmpty else {
            throw ConfigError.invalidHost(localHost)
        }
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missingRequired(String)
    case invalidURL(String)
    case invalidSubdomain(String)
    case invalidAPIKey
    case invalidPort(Int)
    case invalidHost(String)

    public var description: String {
        switch self {
        case .missingRequired(let key):
            return "Missing required configuration: \(key)"
        case .invalidURL(let url):
            return "Invalid server URL: \(url)"
        case .invalidSubdomain(let subdomain):
            return "Invalid subdomain: \(subdomain)"
        case .invalidAPIKey:
            return "Invalid API key"
        case .invalidPort(let port):
            return "Invalid port: \(port)"
        case .invalidHost(let host):
            return "Invalid host: \(host)"
        }
    }
}
