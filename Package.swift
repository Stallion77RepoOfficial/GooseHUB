// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GooseHUB",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "GooseHUB", targets: ["GooseHubApp"]),
        .executable(name: "goosehub-cli", targets: ["GooseHubCLI"]),
        .library(name: "GooseCore", targets: ["GooseCore"])
    ],
    targets: [
        .target(name: "GooseCore"),
        .executableTarget(name: "GooseHubApp", dependencies: ["GooseCore"]),
        .executableTarget(name: "GooseHubCLI", dependencies: ["GooseCore"]),
        .testTarget(name: "GooseCoreTests", dependencies: ["GooseCore"])
    ],
    swiftLanguageModes: [.v5]
)
