// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cok",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "cok-server", targets: ["TunnelServer"]),
        .executable(name: "cok-client", targets: ["TunnelClient"]),
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "TunnelCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        .executableTarget(
            name: "TunnelServer",
            dependencies: [
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-Xfrontend", "-strict-concurrency=complete", "-Xfrontend", "-warn-concurrency",
                ]),
            ]
        ),

        .executableTarget(
            name: "TunnelClient",
            dependencies: [
                "TunnelCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        .testTarget(
            name: "TunnelCoreTests",
            dependencies: ["TunnelCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        .testTarget(
            name: "TunnelServerTests",
            dependencies: [
                "TunnelServer",
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        .testTarget(
            name: "TunnelIntegrationTests",
            dependencies: [
                "TunnelServer",
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
