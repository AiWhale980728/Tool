// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchRelay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .executable(name: "relayctl", targets: ["RelayCLI"]),
        .executable(name: "NotchRelayApp", targets: ["NotchRelayApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .target(
            name: "RelayCore",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .executableTarget(
            name: "RelayCLI",
            dependencies: ["RelayCore"]
        ),
        .executableTarget(
            name: "NotchRelayApp",
            dependencies: ["RelayCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
