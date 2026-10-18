// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoToolCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoToolCore", targets: ["VideoToolCore"]),
    ],
    targets: [
        .target(name: "VideoToolCore"),
        .testTarget(name: "VideoToolCoreTests", dependencies: ["VideoToolCore"]),
    ]
)
