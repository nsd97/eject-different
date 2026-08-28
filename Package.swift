// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EjectDifferent",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EjectDifferentCore", targets: ["EjectDifferentCore"]),
        .executable(name: "eject-different", targets: ["EjectDifferent"]),
    ],
    targets: [
        .target(name: "EjectDifferentCore"),
        .executableTarget(
            name: "EjectDifferent",
            dependencies: ["EjectDifferentCore"],
            resources: [.copy("Resources/different.wav")]
        ),
        .testTarget(name: "EjectDifferentCoreTests", dependencies: ["EjectDifferentCore"]),
    ]
)
