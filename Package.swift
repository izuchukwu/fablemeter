// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeBattery",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeBattery",
            path: "Sources/ClaudeBattery"
        )
    ]
)
