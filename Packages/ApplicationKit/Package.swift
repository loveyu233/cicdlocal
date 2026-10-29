// swift-tools-version: 6.4
// ApplicationKit：供原生界面调用的项目、推送监听、三阶段运行与 k8s 连接用例。
import PackageDescription

let package = Package(
    name: "ApplicationKit",
    platforms: [.macOS(.v27)],
    products: [.library(name: "ApplicationKit", targets: ["ApplicationKit"])],
    dependencies: [
        .package(path: "../Models"), .package(path: "../Storage"),
        .package(path: "../GitKit"), .package(path: "../LogKit"),
        .package(path: "../Platform"), .package(path: "../PushWatch"),
        .package(path: "../Runner"),
        .package(url: "https://github.com/jpsim/Yams.git", .upToNextMinor(from: "6.2.2")),
    ],
    targets: [
        .target(name: "ApplicationKit", dependencies: [
            "Models", "Storage", "GitKit", "LogKit", "Platform", "Runner",
            .product(name: "PushWatch", package: "PushWatch"),
            .product(name: "HookProtocol", package: "PushWatch"),
            .product(name: "Yams", package: "Yams"),
        ]),
        .testTarget(name: "ApplicationKitTests", dependencies: ["ApplicationKit"]),
    ],
    swiftLanguageModes: [.v6]
)
