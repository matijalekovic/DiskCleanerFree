// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCleanerFree",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DiskCleanerFree",
            path: "Sources/DiskCleanerFree",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
