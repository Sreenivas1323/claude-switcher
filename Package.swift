// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSwitcher",
            path: "Sources/ClaudeSwitcher"
        )
    ]
)
