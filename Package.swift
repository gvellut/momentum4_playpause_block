// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Momentum4PlayPauseBlock",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "Momentum4PlayPauseBlock",
            targets: ["Momentum4PlayPauseBlock"]
        ),
        .library(
            name: "Momentum4PlayPauseBlockCore",
            targets: ["Momentum4PlayPauseBlockCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.3"),
    ],
    targets: [
        .target(
            name: "Momentum4PlayPauseBlockCore"
        ),
        .executableTarget(
            name: "Momentum4PlayPauseBlock",
            dependencies: ["Momentum4PlayPauseBlockCore"]
        ),
        .testTarget(
            name: "Momentum4PlayPauseBlockCoreTests",
            dependencies: [
                "Momentum4PlayPauseBlockCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
