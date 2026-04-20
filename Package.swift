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
        .executable(
            name: "Momentum4PlayPauseBlockCLI",
            targets: ["Momentum4PlayPauseBlockCLI"]
        ),
        .executable(
            name: "Momentum4PlayPauseBlockDiagCLI",
            targets: ["Momentum4PlayPauseBlockDiagCLI"]
        ),
        .library(
            name: "Momentum4PlayPauseBlockCommon",
            targets: ["Momentum4PlayPauseBlockCommon"]
        ),
        .library(
            name: "Momentum4PlayPauseBlockAppSupport",
            targets: ["Momentum4PlayPauseBlockAppSupport"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.3"),
    ],
    targets: [
        .target(
            name: "Momentum4PlayPauseBlockCommon"
        ),
        .target(
            name: "Momentum4PlayPauseBlockAppSupport",
            dependencies: ["Momentum4PlayPauseBlockCommon"]
        ),
        .executableTarget(
            name: "Momentum4PlayPauseBlock",
            dependencies: ["Momentum4PlayPauseBlockAppSupport"]
        ),
        .executableTarget(
            name: "Momentum4PlayPauseBlockCLI",
            dependencies: ["Momentum4PlayPauseBlockCommon"]
        ),
        .executableTarget(
            name: "Momentum4PlayPauseBlockDiagCLI"
        ),
        .testTarget(
            name: "Momentum4PlayPauseBlockCommonTests",
            dependencies: [
                "Momentum4PlayPauseBlockCommon",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "Momentum4PlayPauseBlockAppSupportTests",
            dependencies: [
                "Momentum4PlayPauseBlockAppSupport",
                "Momentum4PlayPauseBlockCommon",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "Momentum4PlayPauseBlockCLITests",
            dependencies: [
                "Momentum4PlayPauseBlockCLI",
                "Momentum4PlayPauseBlockCommon",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
