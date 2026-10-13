// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pier", targets: ["pier"]),
        .executable(name: "PierApp", targets: ["PierApp"]),
        .library(name: "PierCore", targets: ["PierCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        .target(name: "PierCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "PierApp", dependencies: ["PierCore"], resources: [.process("Resources")]),
        .executableTarget(
            name: "pier",
            dependencies: [
                "PierCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PierCoreTests", dependencies: ["PierCore"]),
    ],
    swiftLanguageModes: [.v5]
)
