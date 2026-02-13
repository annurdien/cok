import ArgumentParser
import Foundation
import Logging
import TunnelCore

@main
struct CokCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cok",
        abstract: "Cok - Expose your local server to the internet",
        version: "1.0.0",
        subcommands: [Start.self, Status.self],
        defaultSubcommand: Start.self
    )
}

extension CokCLI {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the tunnel client"
        )

        @Option(name: .shortAndLong, help: "Tunnel server URL (wss://tunnel.example.com)")
        var server: String

        @Option(name: .shortAndLong, help: "Desired subdomain (e.g., 'myapp')")
        var subdomain: String

        @Option(name: .shortAndLong, help: "API key for authentication")
        var apiKey: String

        @Option(name: [.customLong("local-host")], help: "Local host to forward to")
        var localHost: String = "127.0.0.1"

        @Option(name: [.customLong("local-port")], help: "Local port to forward to")
        var localPort: Int = 3000

        @Option(name: [.customLong("reconnect-delay")], help: "Reconnect delay in seconds")
        var reconnectDelay: Double = 5.0

        @Option(name: [.customLong("max-reconnect-attempts")], help: "Max reconnect attempts (-1 for infinite)")
        var maxReconnectAttempts: Int = -1

        @Option(name: [.customLong("log-level")], help: "Log level (trace, debug, info, warning, error, critical)")
        var logLevel: String = "info"

        @Flag(name: .shortAndLong, help: "Show verbose logging")
        var verbose: Bool = false

        mutating func run() async throws {
            var logger = Logger(label: "cok.client")
            logger.logLevel = parseLogLevel(verbose ? "debug" : logLevel)

            let config = ClientConfig(
                serverURL: server,
                subdomain: subdomain,
                apiKey: apiKey,
                localHost: localHost,
                localPort: localPort,
                reconnectDelay: reconnectDelay,
                maxReconnectAttempts: maxReconnectAttempts
            )

            logger.info("╔════════════════════════════════════════════════════════════╗")
            logger.info("║         Cok - Tunnel Your Local Server to the Web        ║")
            logger.info("╚════════════════════════════════════════════════════════════╝")
            logger.info("")

            let client = try TunnelClient(config: config, logger: logger)

            try await client.start()

            let publicURL = "https://\(config.subdomain).\(extractHost(from: config.serverURL))"
            let localURL = "http://\(config.localHost):\(config.localPort)"

            logger.info("✓ Tunnel established successfully!")
            logger.info("")
            logger.info("  Public URL:  \(publicURL)")
            logger.info("  Local URL:   \(localURL)")
            logger.info("")
            logger.info("Press Ctrl+C to stop...")
            logger.info("")

            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
            } onCancel: {
                Task {
                    try? await client.stop()
                }
            }
        }

        private func parseLogLevel(_ level: String) -> Logger.Level {
            switch level.lowercased() {
            case "trace": return .trace
            case "debug": return .debug
            case "info": return .info
            case "warning", "warn": return .warning
            case "error": return .error
            case "critical": return .critical
            default: return .info
            }
        }

        private func extractHost(from urlString: String) -> String {
            guard let url = URL(string: urlString), let host = url.host else {
                return "tunnel.example.com"
            }
            return host
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show client status"
        )

        mutating func run() async throws {
            print("Status command not yet implemented")
            print("This will show real-time tunnel status, metrics, and health information")
        }
    }
}
