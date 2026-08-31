// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Tethersnap",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TethersnapKit", targets: ["TethersnapKit"]),
        .executable(name: "tethersnap", targets: ["tethersnap"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "TethersnapKit",
            dependencies: [],
            path: "Sources/TethersnapKit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "tethersnap",
            dependencies: [
                "TethersnapKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Tethersnap"
        ),
        .executableTarget(
            name: "TethersnapApp",
            dependencies: ["TethersnapKit"],
            path: "Sources/TethersnapApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TethersnapKitTests",
            dependencies: ["TethersnapKit"],
            path: "Tests/TethersnapKitTests"
        ),
    ]
)
