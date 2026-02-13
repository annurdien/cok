// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cok",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cok", targets: ["TunnelClient"]),
        .executable(name: "cok-server", targets: ["TunnelServer"]),
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Core shared library
        .target(
            name: "TunnelCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // Server executable
        .executableTarget(
            name: "TunnelServer",
            dependencies: ["TunnelCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // Client executable
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

        // Tests
        .testTarget(
            name: "TunnelCoreTests",
            dependencies: ["TunnelCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
