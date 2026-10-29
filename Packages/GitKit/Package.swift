// swift-tools-version: 6.4
// GitKit：git 命令封装：解析提交、读取提交中的文件、安装监听配置、确认远端引用。
import PackageDescription

let package = Package(
    name: "GitKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
    ],
    dependencies: [
        .package(path: "../Platform"),
        .package(path: "../Models"),
    ],
    targets: [
        .target(
            name: "GitKit",
            dependencies: ["Platform", "Models"]
        ),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "Models"]),
    ],
    swiftLanguageModes: [.v6]
)
