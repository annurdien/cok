import Foundation

public struct ServerConfig: Sendable {
    public let host: String
    public let httpPort: Int
    public let tcpPort: Int
    public let allowedHosts: Set<String>
    public let maxTunnels: Int
    public let apiKeySecret: String
    public let baseDomain: String
    public let healthCheckPaths: Set<String>

    public init(
        host: String = "0.0.0.0",
        httpPort: Int = 8080,
        tcpPort: Int = 5000,
        allowedHosts: Set<String> = ["localhost"],
        maxTunnels: Int = 1000,
        apiKeySecret: String,
        baseDomain: String = "localhost",
        healthCheckPaths: Set<String> = ["/health", "/health/live", "/health/ready"]
    ) {
        self.host = host
        self.httpPort = httpPort
        self.tcpPort = tcpPort
        self.allowedHosts = allowedHosts
        self.maxTunnels = maxTunnels
        self.apiKeySecret = apiKeySecret
        self.baseDomain = baseDomain
        self.healthCheckPaths = healthCheckPaths
    }

    public static func fromEnvironment() throws -> ServerConfig {
        let httpPort = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "8080") ?? 8080
        let tcpPort = Int(ProcessInfo.processInfo.environment["TCP_PORT"] ?? "5000") ?? 5000
        let allowedHostsStr = ProcessInfo.processInfo.environment["ALLOWED_HOSTS"] ?? "localhost"
        let allowedHosts = Set(
            allowedHostsStr.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            })
        let maxTunnels = Int(ProcessInfo.processInfo.environment["MAX_TUNNELS"] ?? "1000") ?? 1000

        guard
            let apiKeySecret = ProcessInfo.processInfo.environment["API_KEY_SECRET"],
            !apiKeySecret.isEmpty
        else {
            throw ServerConfigError.missingRequired("API_KEY_SECRET")
        }

        let baseDomain = ProcessInfo.processInfo.environment["BASE_DOMAIN"] ?? "localhost"
        let healthCheckPathsStr =
            ProcessInfo.processInfo.environment["HEALTH_CHECK_PATHS"]
            ?? "/health,/health/live,/health/ready"
        let healthCheckPaths = Set(
            healthCheckPathsStr.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            })

        return ServerConfig(
            httpPort: httpPort,
            tcpPort: tcpPort,
            allowedHosts: allowedHosts,
            maxTunnels: maxTunnels,
            apiKeySecret: apiKeySecret,
            baseDomain: baseDomain,
            healthCheckPaths: healthCheckPaths
        )
    }
}

public enum ServerConfigError: Error, CustomStringConvertible {
    case missingRequired(String)

    public var description: String {
        switch self {
        case .missingRequired(let key):
            return "Missing required environment variable: \(key)"
        }
    }
}
