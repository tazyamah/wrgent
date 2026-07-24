// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wrgent",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git",
                 .upToNextMinor(from: "1.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "wrgent",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/wrgent"
        )
    ]
)
