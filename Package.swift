// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TetherKit", targets: ["TetherKit"]),
        .executable(name: "tether", targets: ["tether"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "TetherKit",
            dependencies: [],
            path: "Sources/TetherKit"
        ),
        .executableTarget(
            name: "tether",
            dependencies: [
                "TetherKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Tether"
        ),
        .testTarget(
            name: "TetherKitTests",
            dependencies: ["TetherKit"],
            path: "Tests/TetherKitTests"
        ),
    ]
)
