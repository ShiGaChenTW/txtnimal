// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "txtnimalCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "txtnimalCore", targets: ["txtnimalCore"]),
    ],
    targets: [
        .target(name: "txtnimalCore"),
        .testTarget(name: "txtnimalCoreTests", dependencies: ["txtnimalCore"]),
    ]
)
