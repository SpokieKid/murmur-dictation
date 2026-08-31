// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Murmur",
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
