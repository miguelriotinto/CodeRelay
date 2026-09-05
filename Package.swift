// swift-tools-version: 5.9
import PackageDescription

// The server, CLI, and Kit build on macOS and Linux. The two Apple client
// libraries (ClaudeRelayClient: SwiftUI/UIKit/AppKit; ClaudeRelaySpeech:
// WhisperKit/CoreML) and their dependencies exist only on Apple platforms —
// a manifest runs on the host, so `os(Linux)` here means "building on Linux".
#if os(Linux)
let buildsAppleClients = false
#else
let buildsAppleClients = true
#endif

var products: [Product] = [
    .executable(name: "claude-relay-server", targets: ["ClaudeRelayServer"]),
    .executable(name: "claude-relay", targets: ["ClaudeRelayCLI"]),
    .library(name: "ClaudeRelayKit", targets: ["ClaudeRelayKit"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    // Terminal QR codes: CoreImage on Apple platforms, this pure-Swift encoder
    // on Linux (see TerminalQRRenderer). Declared unconditionally so the
    // pin set in Package.resolved is the same on both hosts; only the CLI's
    // link against it is platform-conditional.
    .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.2"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMajor(from: "1.10.0")),
]

// Server integration tests drive a real WebSocket server through the Swift
// client library on Apple platforms. On Linux those three files are excluded
// and the same scenarios run through the NIO-based test client instead.
var serverTestDependencies: [Target.Dependency] = ["ClaudeRelayServer", "ClaudeRelayKit"]
var serverTestExcludes: [String] = []

var targets: [Target] = [
    .target(
        name: "CPTYShim",
        path: "Sources/CPTYShim",
        publicHeadersPath: "include",
        linkerSettings: [
            // forkpty(3) lives in libutil on glibc < 2.34 and in libc after;
            // libutil is still shipped as a stub there, so linking it is
            // correct on both.
            .linkedLibrary("util", .when(platforms: [.linux])),
        ]
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
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
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
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator",
                     condition: .when(platforms: [.linux])),
        ],
        path: "Sources/ClaudeRelayCLI"
    ),
    .testTarget(
        name: "ClaudeRelayKitTests",
        dependencies: ["ClaudeRelayKit"],
        path: "Tests/ClaudeRelayKitTests"
    ),
    .testTarget(
        name: "ClaudeRelayCLITests",
        dependencies: ["ClaudeRelayCLI", "ClaudeRelayKit"],
        path: "Tests/ClaudeRelayCLITests"
    ),
]

if buildsAppleClients {
    products += [
        .library(name: "ClaudeRelayClient", targets: ["ClaudeRelayClient"]),
        .library(name: "ClaudeRelaySpeech", targets: ["ClaudeRelaySpeech"]),
    ]
    dependencies += [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
    ]
    serverTestDependencies.append("ClaudeRelayClient")
    targets += [
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
} else {
    serverTestExcludes = [
        "ReplayRepaintTests.swift",
        "UnattachedRequestReplyTests.swift",
        "WebSocketIntegrationTests.swift",
    ]
}

targets.append(
    .testTarget(
        name: "ClaudeRelayServerTests",
        dependencies: serverTestDependencies,
        path: "Tests/ClaudeRelayServerTests",
        exclude: serverTestExcludes
    )
)

let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
