import ArgumentParser
import Foundation
import Logging
import TunnelCore

@main
struct CokCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cok",
        abstract: "Expose your local server to the internet",
        version: "0.1.0"
    )

    @Option(name: .shortAndLong, help: "Local port to forward")
    var port: Int

    @Option(name: .shortAndLong, help: "Subdomain (auto-generated if not provided)")
    var subdomain: String?

    @Option(name: [.customLong("api-key")], help: "API key for authentication")
    var apiKey: String?

    @Option(name: .long, help: "Tunnel server URL")
    var server: String?

    @Option(name: .long, help: "Local host to forward to")
    var host: String = "localhost"

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        var logger = Logger(label: "cok")
        logger.logLevel = verbose ? .debug : .info

        let resolvedSubdomain = subdomain ?? generateSubdomain()
        let resolvedApiKey = apiKey ?? ProcessInfo.processInfo.environment["COK_API_KEY"] ?? ""
        let resolvedServer = server ?? ProcessInfo.processInfo.environment["COK_SERVER_URL"] ?? "ws://localhost:8081"

        let config = ClientConfig(
            serverURL: resolvedServer,
            subdomain: resolvedSubdomain,
            apiKey: resolvedApiKey,
            localHost: host,
            localPort: port
        )

        print("")
        print("  cok - tunnel to the web")
        print("")

        let client = try TunnelClient(config: config, logger: logger)
        try await client.start()

        let serverHost = extractHost(from: config.serverURL)
        let publicURL = "https://\(resolvedSubdomain).\(serverHost)"

        print("  ✓ Tunnel established!")
        print("")
        print("  Forwarding:  \(publicURL)")
        print("         to:   http://\(host):\(port)")
        print("")
        print("  Press Ctrl+C to stop")
        print("")

        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        } onCancel: {
            Task { try? await client.stop() }
        }
    }

    private func generateSubdomain() -> String {
        let adjectives = ["swift", "quick", "bright", "cool", "fast", "neat", "sharp", "bold"]
        let nouns = ["tunnel", "link", "path", "gate", "port", "node", "pipe", "route"]
        let adj = adjectives.randomElement() ?? "swift"
        let noun = nouns.randomElement() ?? "tunnel"
        let num = Int.random(in: 100...999)
        return "\(adj)-\(noun)-\(num)"
    }

    private func extractHost(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return "localhost"
        }
        return host
    }
}
