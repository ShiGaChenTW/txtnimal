// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "txtnimalCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "txtnimalCore", targets: ["txtnimalCore"]),
        .executable(name: "txtnimal", targets: ["txtnimalCLI"]),
    ],
    targets: [
        .target(name: "txtnimalCore"),
        .testTarget(name: "txtnimalCoreTests", dependencies: ["txtnimalCore"]),
        // CLI logic lives in a library so it is unit-testable; the executable is a
        // three-line shim. Testing an executable target directly is unreliable on
        // macOS once `main.swift` top-level code is involved.
        .target(name: "txtnimalCLICore", dependencies: ["txtnimalCore"]),
        .executableTarget(name: "txtnimalCLI", dependencies: ["txtnimalCLICore"]),
        .testTarget(name: "txtnimalCLICoreTests", dependencies: ["txtnimalCLICore", "txtnimalCore"]),
    ]
)
