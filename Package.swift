// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fablemeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fablemeter",
            path: "Sources/Fablemeter"
        )
    ]
)
