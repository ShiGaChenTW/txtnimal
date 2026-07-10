// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TasksTxtCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TasksTxtCore", targets: ["TasksTxtCore"]),
    ],
    targets: [
        .target(name: "TasksTxtCore"),
        .testTarget(name: "TasksTxtCoreTests", dependencies: ["TasksTxtCore"]),
    ]
)
