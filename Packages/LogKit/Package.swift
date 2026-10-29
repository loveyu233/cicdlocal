// swift-tools-version: 6.4
// LogKit：日志管线：UTF-8/ANSI 处理、脱敏、分段落盘。
import PackageDescription

let package = Package(
    name: "LogKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "LogKit", targets: ["LogKit"]),
    ],
    dependencies: [
        .package(path: "../Models"),
    ],
    targets: [
        .target(
            name: "LogKit",
            dependencies: ["Models"]
        ),
        .testTarget(name: "LogKitTests", dependencies: ["LogKit"]),
    ],
    swiftLanguageModes: [.v6]
)
