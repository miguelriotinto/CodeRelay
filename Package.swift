// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "claude-relay-server", targets: ["ClaudeRelayServer"]),
        .executable(name: "claude-relay", targets: ["ClaudeRelayCLI"]),
        .library(name: "ClaudeRelayKit", targets: ["ClaudeRelayKit"]),
        .library(name: "ClaudeRelayClient", targets: ["ClaudeRelayClient"]),
        .library(name: "ClaudeRelaySpeech", targets: ["ClaudeRelaySpeech"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CPTYShim",
            path: "Sources/CPTYShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ClaudeRelayKit",
            dependencies: [
                "CPTYShim",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ClaudeRelayKit"
        ),
        .executableTarget(
            name: "ClaudeRelayServer",
            dependencies: [
                "ClaudeRelayKit",
                "CPTYShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/ClaudeRelayServer",
            resources: [
                .copy("Resources/Agents"),
            ]
        ),
        .executableTarget(
            name: "ClaudeRelayCLI",
            dependencies: [
                "ClaudeRelayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ClaudeRelayCLI"
        ),
        .target(
            name: "ClaudeRelayClient",
            dependencies: ["ClaudeRelayKit"],
            path: "Sources/ClaudeRelayClient"
        ),
        .target(
            name: "ClaudeRelaySpeech",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "LLM", package: "LLM.swift"),
            ],
            path: "Sources/ClaudeRelaySpeech",
            resources: [
                .copy("Resources/SileroVAD.mlmodelc"),
                .copy("Resources/WhisperLogMel8s.mlpackage"),
                .copy("Resources/SmartTurnV3.mlpackage"),
            ]
        ),
        .testTarget(
            name: "ClaudeRelayKitTests",
            dependencies: ["ClaudeRelayKit"],
            path: "Tests/ClaudeRelayKitTests"
        ),
        .testTarget(
            name: "ClaudeRelayServerTests",
            dependencies: ["ClaudeRelayServer", "ClaudeRelayKit", "ClaudeRelayClient"],
            path: "Tests/ClaudeRelayServerTests"
        ),
        .testTarget(
            name: "ClaudeRelayCLITests",
            dependencies: ["ClaudeRelayCLI", "ClaudeRelayKit"],
            path: "Tests/ClaudeRelayCLITests"
        ),
        .testTarget(
            name: "ClaudeRelayClientTests",
            dependencies: ["ClaudeRelayClient"],
            path: "Tests/ClaudeRelayClientTests"
        ),
        .testTarget(
            name: "ClaudeRelaySpeechTests",
            dependencies: ["ClaudeRelaySpeech"],
            path: "Tests/ClaudeRelaySpeechTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
