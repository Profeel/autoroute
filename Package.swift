// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutoModel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AutoModelCore",
            targets: ["AutoModelCore"]
        ),
        .executable(
            name: "AutoModel",
            targets: ["AutoModel"]
        )
    ],
    targets: [
        .target(
            name: "AutoModelCore",
            path: "Sources/AutoModelCore"
        ),
        .executableTarget(
            name: "AutoModel",
            dependencies: ["AutoModelCore"],
            path: "Sources/AutoModel"
        ),
        .testTarget(
            name: "AutoModelCoreTests",
            dependencies: ["AutoModelCore"],
            path: "Tests/AutoModelCoreTests"
        )
    ]
)
