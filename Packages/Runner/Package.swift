// swift-tools-version: 6.4
// Runner：.local.cicd.yml 三阶段配置，以及在本机项目目录里执行测试、构建推送、替换镜像。
import PackageDescription

let package = Package(
    name: "Runner",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Runner", targets: ["Runner"]),
    ],
    dependencies: [
        .package(path: "../Platform"),
        .package(path: "../LogKit"),
        .package(url: "https://github.com/jpsim/Yams.git", .upToNextMinor(from: "6.2.2")),
    ],
    targets: [
        .target(
            name: "Runner",
            dependencies: ["Platform", "LogKit", .product(name: "Yams", package: "Yams")]
        ),
        .testTarget(name: "RunnerTests", dependencies: ["Runner", "Platform", "LogKit"]),
    ],
    swiftLanguageModes: [.v6]
)
