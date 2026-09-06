// swift-tools-version: 6.3

import PackageDescription

private let bridgeDependencies: [PackageDescription.Target.Dependency] = [
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "Logging", package: "swift-log")
]

let package = Package(
    name: "ios-dev-sandbox-host",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "host-bridge", targets: ["HostBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "HostBridge",
            dependencies: bridgeDependencies
        ),
        .testTarget(
            name: "HostBridgeTests",
            dependencies: ["HostBridge"]
        )
    ]
)
