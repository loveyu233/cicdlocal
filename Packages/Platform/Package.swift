// swift-tools-version: 6.4
// Platform：子进程封装、钥匙串、文件锁、路径与目录布局。
import PackageDescription

let package = Package(
    name: "Platform",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Platform", targets: ["Platform"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "1.0.2")),
    ],
    targets: [
        .target(
            name: "Platform",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")]
        ),
        .testTarget(name: "PlatformTests", dependencies: ["Platform"]),
    ],
    swiftLanguageModes: [.v6]
)
