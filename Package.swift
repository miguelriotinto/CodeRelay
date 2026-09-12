// swift-tools-version: 5.9
import PackageDescription

// The server, CLI, and Kit build on macOS and Linux. The two Apple client
// libraries (CodeRelayClient: SwiftUI/UIKit/AppKit; CodeRelaySpeech:
// WhisperKit/CoreML) and their dependencies exist only on Apple platforms —
// a manifest runs on the host, so `os(Linux)` here means "building on Linux".
#if os(Linux)
let buildsAppleClients = false
#else
let buildsAppleClients = true
#endif

var products: [Product] = [
    .executable(name: "claude-relay-server", targets: ["CodeRelayServer"]),
    .executable(name: "claude-relay", targets: ["CodeRelayCLI"]),
    .library(name: "CodeRelayKit", targets: ["CodeRelayKit"]),
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
var serverTestDependencies: [Target.Dependency] = ["CodeRelayServer", "CodeRelayKit"]
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
        name: "CodeRelayKit",
        dependencies: [
            "CPTYShim",
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        path: "Sources/CodeRelayKit"
    ),
    .executableTarget(
        name: "CodeRelayServer",
        dependencies: [
            "CodeRelayKit",
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
        path: "Sources/CodeRelayServer",
        resources: [
            .copy("Resources/Agents"),
        ]
    ),
    .executableTarget(
        name: "CodeRelayCLI",
        dependencies: [
            "CodeRelayKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator",
                     condition: .when(platforms: [.linux])),
        ],
        path: "Sources/CodeRelayCLI"
    ),
    .testTarget(
        name: "CodeRelayKitTests",
        dependencies: ["CodeRelayKit"],
        path: "Tests/CodeRelayKitTests"
    ),
    .testTarget(
        name: "CodeRelayCLITests",
        dependencies: ["CodeRelayCLI", "CodeRelayKit"],
        path: "Tests/CodeRelayCLITests"
    ),
]

if buildsAppleClients {
    products += [
        .library(name: "CodeRelayClient", targets: ["CodeRelayClient"]),
        .library(name: "CodeRelaySpeech", targets: ["CodeRelaySpeech"]),
    ]
    dependencies += [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
    ]
    serverTestDependencies.append("CodeRelayClient")
    targets += [
        .target(
            name: "CodeRelayClient",
            dependencies: ["CodeRelayKit"],
            path: "Sources/CodeRelayClient"
        ),
        .target(
            name: "CodeRelaySpeech",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "LLM", package: "LLM.swift"),
            ],
            path: "Sources/CodeRelaySpeech",
            resources: [
                .copy("Resources/SileroVAD.mlmodelc"),
                .copy("Resources/WhisperLogMel8s.mlpackage"),
                .copy("Resources/SmartTurnV3.mlpackage"),
            ]
        ),
        .testTarget(
            name: "CodeRelayClientTests",
            dependencies: ["CodeRelayClient"],
            path: "Tests/CodeRelayClientTests"
        ),
        .testTarget(
            name: "CodeRelaySpeechTests",
            dependencies: ["CodeRelaySpeech"],
            path: "Tests/CodeRelaySpeechTests",
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
        name: "CodeRelayServerTests",
        dependencies: serverTestDependencies,
        path: "Tests/CodeRelayServerTests",
        exclude: serverTestExcludes
    )
)

let package = Package(
    name: "CodeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
