// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cok",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "cok-server", targets: ["TunnelServer"]),
        .executable(name: "cok", targets: ["TunnelClient"]),
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.94.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),
        .package(url: "https://github.com/the-swift-collective/zlib.git", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "TunnelCore",
            dependencies: [
                .product(name: "ZLib", package: "zlib"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .executableTarget(
            name: "TunnelServer",
            dependencies: [
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),

        .executableTarget(
            name: "TunnelClient",
            dependencies: [
                "TunnelCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),

        .testTarget(
            name: "TunnelCoreTests",
            dependencies: ["TunnelCore"]
        ),

        .testTarget(
            name: "TunnelServerTests",
            dependencies: [
                "TunnelServer",
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .testTarget(
            name: "TunnelClientTests",
            dependencies: [
                "TunnelClient",
                "TunnelCore",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .testTarget(
            name: "TunnelIntegrationTests",
            dependencies: [
                "TunnelServer",
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .executableTarget(
            name: "Benchmarks",
            dependencies: [
                "TunnelCore",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Benchmarks"
        ),
    ]
)
