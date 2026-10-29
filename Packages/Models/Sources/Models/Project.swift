import Foundation

/// 用户添加的本地仓库。推送后在这个目录里执行 `.local.cicd.yml`。
public struct Project: Identifiable, Hashable, Sendable, Codable {
    public var id: ProjectID
    public var name: String
    /// 仓库工作目录的绝对路径。
    public var repositoryPath: String
    public var hookMode: HookMode
    public var createdAt: Date

    public init(id: ProjectID, name: String, repositoryPath: String, hookMode: HookMode = .none, createdAt: Date) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.hookMode = hookMode
        self.createdAt = createdAt
    }
}

/// 推送钩子的安装方式。
public enum HookMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// 未安装，推送不会触发运行。
    case none
    /// 仓库本地配置中的配置式钩子（Git ≥ 2.54）。
    case configHook = "config_hook"
    /// 在钩子目录中链式包装原有钩子。
    case chainedWrapper = "chained_wrapper"
}
