// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacJanitor",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacJanitorGUI", targets: ["MacJanitor"]),
        .executable(name: "macjanitor", targets: ["MacJanitorCLI"]),
    ],
    targets: [
        .target(name: "MacJanitorCore"),
        .executableTarget(name: "MacJanitor", dependencies: ["MacJanitorCore"], path: "Sources/MacJanitor"),
        .executableTarget(name: "MacJanitorCLI", dependencies: ["MacJanitorCore"]),
        .testTarget(name: "MacJanitorTests", dependencies: ["MacJanitor", "MacJanitorCore"], path: "Tests/MacJanitorTests"),
    ]
)
