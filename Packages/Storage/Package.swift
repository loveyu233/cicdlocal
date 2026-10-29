// swift-tools-version: 6.4
// Storage：GRDB 数据库、迁移、仓储、观察。
import PackageDescription

let package = Package(
    name: "Storage",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Storage", targets: ["Storage"]),
    ],
    dependencies: [
        .package(path: "../Models"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "7.11.1")),
    ],
    targets: [
        .target(
            name: "Storage",
            dependencies: ["Models", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "Models", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
