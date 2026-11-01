// swift-tools-version: 5.9
import PackageDescription

// FlipStack — the minimal main application, focused exclusively on guided
// manual duplex printing. The previous, feature-rich implementation lives in
// Advanced/ as a standalone package and is preserved there unchanged.
let package = Package(
    name: "FlipStack",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FlipStack", targets: ["FlipStack"]),
        .library(name: "FlipStackCore", targets: ["FlipStackCore"])
    ],
    targets: [
        .target(
            name: "FlipStackCore",
            path: "Sources/FlipStackCore"
        ),
        .executableTarget(
            name: "FlipStack",
            dependencies: ["FlipStackCore"],
            path: "Sources/FlipStack"
        ),
        .testTarget(
            name: "FlipStackCoreTests",
            dependencies: ["FlipStackCore"],
            path: "Tests/FlipStackCoreTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
