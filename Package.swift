// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PingBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PingBar", targets: ["PingBar"])
    ],
    targets: [
        .target(name: "PingBarCore"),
        .executableTarget(
            name: "PingBar",
            dependencies: ["PingBarCore"]
        ),
        .testTarget(
            name: "PingBarCoreTests",
            dependencies: ["PingBarCore"]
        )
    ]
)
