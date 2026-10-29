import CryptoKit
import Foundation
import GitKit
import HookProtocol

public struct InstalledHooks: Codable, Sendable, Equatable {
    public var installation: HookInstallation
    public var helperPath: String
    public var helperSHA256: String
    public var configurationPath: String
    public var hooks: [GitConfigHook]
}

/// 只读生成的安装计划；预览和实际写入共享同一组名称与路径。
public struct HookInstallPlan: Sendable, Identifiable {
    public let id: UUID
    public let repositoryPath: String
    public let root: URL
    public let hooks: [GitConfigHook]
    public let commands: [String]
}

public struct HookInstaller: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// 只能由用户明确开启项目监听后调用。原钩子保留文件、参数、标准输入与拒绝行为。
    public func install(repository: GitRepository, projectID: Int64, helper: URL, plan: HookInstallPlan? = nil) async throws -> InstalledHooks {
        try await prepare(repository: repository, projectID: projectID, helper: helper, plan: plan)
    }

    public func preview(repository: GitRepository) async throws -> HookInstallPlan {
        guard try await repository.supportsConfigHooks() else {
            throw HookFailure("当前 Git 低于 2.54，尚不支持安装推送监听；仍可添加项目并手动运行")
        }
        let id = UUID()
        let root = directory.appendingPathComponent("installation-\(id.uuidString)")
        let hooks = Self.hooks(id: id, root: root)
        let prefix = [repository.executable, "-C", repository.root.path, "config", "--local", "--add"].map(Self.quote).joined(separator: " ")
        let commands = hooks.flatMap { hook in
            zip(["event", "command", "enabled"], [hook.event, hook.command, "true"]).map { field, value in
                prefix + " " + Self.quote("hook.\(hook.name).\(field)") + " " + Self.quote(value)
            }
        }
        return HookInstallPlan(id: id, repositoryPath: repository.root.path, root: root, hooks: hooks, commands: commands)
    }

    private static func hooks(id: UUID, root: URL) -> [GitConfigHook] {
        let prefix = "localcicd-\(id.uuidString.lowercased())"
        return ["pre-push", "reference-transaction"].map { event in
            GitConfigHook(name: "\(prefix)-\(event)", event: event,
                command: "exec \(quote(root.appendingPathComponent("localcicd-hook").path)) \(event) \(quote(root.appendingPathComponent("hook.json").path))")
        }
    }

    private func prepare(repository: GitRepository, projectID: Int64, helper: URL, plan: HookInstallPlan? = nil) async throws -> InstalledHooks {
        guard try await repository.supportsConfigHooks() else {
            throw HookFailure("当前 Git 低于 2.54，推送监听需要使用 Git 2.54 或以上版本")
        }
        let store = try HookSpool(root: directory.appendingPathComponent("project-\(projectID)", isDirectory: true))
        let manifest = store.root.appendingPathComponent("installation.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let installed = try store.read(InstalledHooks.self, name: "installation.json")
            guard installed.installation.repositoryPath == repository.root.path, try await isIntact(installed, repository: repository) else {
                throw HookFailure("监听安装记录与当前项目不一致或文件已变化，请检查后修复")
            }
            return installed
        }
        if let plan {
            guard plan.repositoryPath == repository.root.path,
                  plan.root == directory.appendingPathComponent("installation-\(plan.id.uuidString)"),
                  plan.hooks == Self.hooks(id: plan.id, root: plan.root) else {
                throw HookFailure("安装计划已失效，请重新预览当前仓库的监听配置")
            }
        }
        let payload = try HookSpool(root: plan?.root ?? store.root)
        let destination = payload.root.appendingPathComponent("localcicd-hook")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw HookFailure("应用内的钩子辅助程序缺失") }
        let data = try Data(contentsOf: helper, options: .mappedIfSafe)
        guard data.count <= 64 * 1_024 * 1_024 else { throw HookFailure("钩子辅助程序超过大小限制") }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        let configuration = HookInstallation(
            id: plan?.id ?? UUID(), projectID: projectID, repositoryPath: repository.root.path, gitExecutable: repository.executable,
            spoolPath: store.root.appendingPathComponent("spool", isDirectory: true).path)
        let configurationPath = payload.root.appendingPathComponent("hook.json").path
        try payload.write(configuration, name: "hook.json")
        _ = try HookSpool(root: URL(fileURLWithPath: configuration.spoolPath))
        let hooks = Self.hooks(id: configuration.id, root: payload.root)
        let installed = InstalledHooks(
            installation: configuration, helperPath: destination.path,
            helperSHA256: Self.digest(data), configurationPath: configurationPath, hooks: hooks)
        // 先保存恢复信息；失败时仍能准确找到自己创建的文件与配置。
        try store.write(installed, name: "installation.json")
        do { try await repository.updateConfigHooks(hooks) }
        catch {
            try? FileManager.default.removeItem(at: manifest)
            throw error
        }
        return installed
    }

    public func uninstall(_ installed: InstalledHooks, repository: GitRepository) async throws {
        guard installed.installation.repositoryPath == repository.root.path else { throw HookFailure("监听不属于当前项目") }
        try await repository.updateConfigHooks(installed.hooks, removing: true)
        // 保留历史 spool；只移除安装标记，旧证据不会被当作新安装的事件。
        let manifest = directory.appendingPathComponent("project-\(installed.installation.projectID)/installation.json")
        try FileManager.default.removeItem(at: manifest)
    }

    public func isIntact(_ installed: InstalledHooks, repository: GitRepository) async throws -> Bool {
        guard installed.installation.repositoryPath == repository.root.path,
            FileManager.default.isExecutableFile(atPath: installed.helperPath),
            URL(fileURLWithPath: installed.helperPath).resolvingSymlinksInPath().path == installed.helperPath,
            let data = try? Data(contentsOf: URL(fileURLWithPath: installed.helperPath), options: .mappedIfSafe),
            data.count <= 64 * 1_024 * 1_024,
            Self.digest(data) == installed.helperSHA256,
            let configuration = try? HookSpool.read(HookInstallation.self, url: URL(fileURLWithPath: installed.configurationPath)),
            configuration == installed.installation
        else { return false }
        for hook in installed.hooks where try await !repository.configHookMatches(hook) { return false }
        return true
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
