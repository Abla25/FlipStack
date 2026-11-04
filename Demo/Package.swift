// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlipStackDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "FlipStackDemo",
            dependencies: [.product(name: "FlipStackCore", package: "FlipStack")],
            path: "Sources/FlipStackDemo"
        ),
        .testTarget(
            name: "FlipStackDemoTests",
            dependencies: ["FlipStackDemo"],
            path: "Tests/FlipStackDemoTests"
        ),
    ]
)
