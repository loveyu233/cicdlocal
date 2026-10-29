// swift-tools-version: 6.4
// PushWatch：spool、三层确认、去重、钩子安装与卸载、自检。
import PackageDescription

let package = Package(
    name: "PushWatch",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "PushWatch", targets: ["PushWatch"]),
        .library(name: "HookProtocol", targets: ["HookProtocol"]),
        .executable(name: "localcicd-hook", targets: ["HookCLI"]),
    ],
    dependencies: [
        .package(path: "../Models"),
        .package(path: "../GitKit"),
        .package(path: "../Storage"),
        .package(path: "../Platform"),
    ],
    targets: [
        .target(
            name: "PushWatch",
            dependencies: ["Models", "GitKit", "Storage", "Platform", "HookProtocol"]
        ),
        .target(name: "HookProtocol"),
        .executableTarget(name: "HookCLI", dependencies: ["HookProtocol"]),
        .testTarget(name: "PushWatchTests", dependencies: ["PushWatch"]),
    ],
    swiftLanguageModes: [.v6]
)
