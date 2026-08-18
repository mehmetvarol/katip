// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Katip",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Katip",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
