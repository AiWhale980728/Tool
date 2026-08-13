// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchRelay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .executable(name: "relayctl", targets: ["RelayCLI"])
    ],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(
            name: "RelayCLI",
            dependencies: ["RelayCore"]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"]
        )
    ]
)
