// swift-tools-version: 6.4
// Models：领域模型、状态枚举、ID 类型。不依赖任何包。
import PackageDescription

let package = Package(
    name: "Models",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Models", targets: ["Models"]),
    ],
    targets: [
        .target(
            name: "Models",
            dependencies: []
        ),
        .testTarget(name: "ModelsTests", dependencies: ["Models"]),
    ],
    swiftLanguageModes: [.v6]
)
