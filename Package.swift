// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DumpShop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DumpShop",
            path: "Sources/DumpShop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
