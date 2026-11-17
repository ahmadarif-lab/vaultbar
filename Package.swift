// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VaultBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that has no AppKit dependency: TOTP, vault models, search,
        // the `bw` CLI wrapper and the demo vault. Unit-tested in isolation.
        .target(
            name: "VaultKit",
            path: "Sources/VaultKit"
        ),
        .executableTarget(
            name: "VaultBar",
            dependencies: ["VaultKit"],
            path: "Sources/VaultBar"
        ),
        .testTarget(
            name: "VaultKitTests",
            dependencies: ["VaultKit"],
            path: "Tests/VaultKitTests"
        ),
    ]
)
