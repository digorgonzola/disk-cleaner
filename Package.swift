// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskCleaner", targets: ["DiskCleaner"]),
        .executable(name: "disk-cleaner", targets: ["disk-cleaner-cli"]),
    ],
    targets: [
        .target(name: "DiskCleanerCore"),
        .executableTarget(name: "DiskCleaner", dependencies: ["DiskCleanerCore"]),
        .executableTarget(name: "disk-cleaner-cli", dependencies: ["DiskCleanerCore"]),
        .testTarget(name: "DiskCleanerCoreTests", dependencies: ["DiskCleanerCore"]),
    ]
)
