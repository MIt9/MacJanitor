// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacJanitor",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MacJanitor", path: "Sources/MacJanitor"),
        .testTarget(name: "MacJanitorTests", dependencies: ["MacJanitor"], path: "Tests/MacJanitorTests"),
    ]
)
