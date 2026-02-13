import Foundation

public struct ServerConfig: Sendable {
    public let httpPort: Int
    public let wsPort: Int
    public let allowedHosts: Set<String>
    public let maxTunnels: Int
    public let apiKeySecret: String

    public init(
        httpPort: Int = 8080,
        wsPort: Int = 5000,
        allowedHosts: Set<String> = ["localhost"],
        maxTunnels: Int = 1000,
        apiKeySecret: String
    ) {
        self.httpPort = httpPort
        self.wsPort = wsPort
        self.allowedHosts = allowedHosts
        self.maxTunnels = maxTunnels
        self.apiKeySecret = apiKeySecret
    }

    public static func fromEnvironment() -> ServerConfig {
        let httpPort = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "8080") ?? 8080
        let wsPort = Int(ProcessInfo.processInfo.environment["WS_PORT"] ?? "5000") ?? 5000
        let allowedHostsStr = ProcessInfo.processInfo.environment["ALLOWED_HOSTS"] ?? "localhost"
        let allowedHosts = Set(
            allowedHostsStr.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            })
        let maxTunnels = Int(ProcessInfo.processInfo.environment["MAX_TUNNELS"] ?? "1000") ?? 1000
        let apiKeySecret =
            ProcessInfo.processInfo.environment["API_KEY_SECRET"] ?? "change-me-in-production"

        return ServerConfig(
            httpPort: httpPort,
            wsPort: wsPort,
            allowedHosts: allowedHosts,
            maxTunnels: maxTunnels,
            apiKeySecret: apiKeySecret
        )
    }
}
