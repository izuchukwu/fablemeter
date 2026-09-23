// swift-tools-version: 5.9
import PackageDescription

// Three targets:
//   FablemeterCore   — everything that talks to Anthropic, the web companion and
//                      Slack, plus the pure policy the selftest proves. Foundation
//                      only, so it builds on Linux for the headless server.
//   Fablemeter       — the macOS menu bar app (AppKit, SwiftUI).
//   fablemeter-server — the headless Linux/macOS daemon and CLI.
//
// The core is compiled with `-enable-testing` and imported `@testable`. That is
// deliberate: it keeps the core's API `internal` exactly as it was when this was
// one target, instead of a few hundred `public` annotations that would change
// nothing but the diff. It costs a little whole-module optimization, which a
// menu bar gauge polling every five minutes does not miss.
let package = Package(
    name: "Fablemeter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fablemeter", targets: ["Fablemeter"]),
        .executable(name: "fablemeter-server", targets: ["FablemeterServer"]),
    ],
    dependencies: [
        // SHA-256 for PKCE where CryptoKit does not exist. Linked on Linux only.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "FablemeterCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/FablemeterCore",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(
            name: "Fablemeter",
            dependencies: ["FablemeterCore"],
            path: "Sources/Fablemeter"
        ),
        .executableTarget(
            name: "FablemeterServer",
            dependencies: ["FablemeterCore"],
            path: "Sources/FablemeterServer"
        ),
    ]
)
