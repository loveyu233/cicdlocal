import ApplicationKit
import CryptoKit
import Foundation
import Platform
import Runner

nonisolated enum AppLaunchEnvironment {
    static func makeService(notify: @escaping @Sendable (RunNotice) async -> Void) throws -> ApplicationService {
        #if DEBUG
        // 界面测试和验收脚本：只接受 .test-repos 下由脚本登记的 cicddemo 隔离副本，数据与钥匙串条目都与正式数据分开。
        if let value = ProcessInfo.processInfo.environment["LOCALCICD_UI_TEST_ROOT"] {
            let root = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
            let marker = root.appending(path: "repository/.git/localcicd-test-source")
            guard let allowed = ProcessInfo.processInfo.environment["LOCALCICD_TEST_SOURCE"],
                  URL(fileURLWithPath: allowed).lastPathComponent == "cicddemo",
                  root.deletingLastPathComponent().lastPathComponent == ".test-repos",
                  root.lastPathComponent.hasPrefix("cicddemo-ui-"),
                  try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == allowed else {
                throw ApplicationError("界面测试只接受已登记的 cicddemo 隔离副本")
            }
            let identifier = SHA256.hash(data: Data(root.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            // 测试目录里的 bin 放在 PATH 最前面，用假 kubectl 代替真实集群。
            let bin = root.appending(path: "bin").path
            return try ApplicationService(
                paths: AppPaths(applicationSupport: root.appending(path: "ui-support")),
                secrets: KeychainSecretStore(service: AppPaths.bundleIdentifier + ".ui-test." + identifier, mode: .fileBased),
                environment: {
                    var environment = try await ShellEnvironment.capture()
                    environment.variables["PATH"] = bin + ":" + (environment.variables["PATH"] ?? "/usr/bin:/bin")
                    return environment
                },
                notify: notify)
        }
        #endif
        return try ApplicationService(paths: AppPaths.standard(), secrets: KeychainSecretStore(mode: .fileBased), notify: notify)
    }
}
