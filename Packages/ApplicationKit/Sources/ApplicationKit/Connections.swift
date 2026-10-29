import Foundation
import GitKit
import Models
import Runner

/// 项目概览：当前分支和 HEAD 上 `.local.cicd.yml` 的检查结果。
public struct ProjectOverview: Sendable, Equatable {
    public var branch: String?
    public var commit: CommitSHA
    /// 没有配置文件或配置有错时为 nil。
    public var config: LocalConfig?
    /// 配置文件缺失或有错的原因。
    public var problem: String?
    /// 配置里引用、但 App 里还没有导入的 k8s 连接名。
    public var missingConnections: [String]
}

extension ApplicationService {
    public func projectOverview(projectID: ProjectID) async throws -> ProjectOverview {
        let repository = try await GitRepository.open(URL(fileURLWithPath: project(projectID).repositoryPath))
        let commit = try await repository.resolve()
        var overview = ProjectOverview(branch: try await repository.currentBranch(), commit: commit, missingConnections: [])
        do {
            guard let data = try await repository.fileContents(LocalConfig.path, at: commit, limit: LocalConfig.maximumBytes) else {
                overview.problem = "当前提交里没有 \(LocalConfig.path)，推送后不会运行"
                return overview
            }
            let config = try LocalConfig.parse(data)
            let known = Set(try await database.connections().map(\.name))
            overview.config = config
            overview.missingConnections = config.connectionNames.filter { !known.contains($0) }
        } catch let error as ConfigError {
            overview.problem = "配置错误：\(error)"
        } catch let error as GitError {
            overview.problem = "配置错误：\(error)"
        }
        return overview
    }

    /// 当前 HEAD 的配置里引用了这个连接名的项目，删除或改名前提示用户。
    public func projectsReferencing(connectionName name: String) async throws -> [String] {
        var names: [String] = []
        for project in try await database.projects() {
            guard let overview = try? await projectOverview(projectID: project.id),
                  overview.config?.connectionNames.contains(name) == true else { continue }
            names.append(project.name)
        }
        return names
    }

    // MARK: - k8s 连接

    /// 导入一个 kubeconfig 并命名。kubeconfig 只写入钥匙串，数据库只记名字和展示信息。
    @discardableResult
    public func importConnection(name: String, preview: KubeconfigPreview) async throws -> K8sConnection {
        guard let name = K8sConnection.normalizedName(name) else { throw ApplicationError("连接名不能为空，最多 64 个字符") }
        guard try await database.connection(named: name) == nil else { throw ApplicationError("已经有名为「\(name)」的 k8s 连接") }
        let account = K8sConnection.newAccount()
        try await secrets.setValue(preview.payload, account: account, label: "本地 CI k8s：\(name)")
        do {
            return try await database.createConnection(K8sConnection(id: .unsaved, name: name, account: account,
                                                                    metadata: metadata(preview), createdAt: Date()))
        } catch {
            try? await secrets.removeValue(account: account)
            throw error
        }
    }

    /// 用新的 kubeconfig 替换连接内容，名字不变。
    public func replaceConnection(_ id: K8sConnectionID, preview: KubeconfigPreview) async throws {
        guard let connection = try await database.connections().first(where: { $0.id == id }) else {
            throw ApplicationError("连接已被删除")
        }
        try await secrets.setValue(preview.payload, account: connection.account, label: "本地 CI k8s：\(connection.name)")
        try await database.updateConnectionMetadata(id, metadata: metadata(preview))
    }

    @discardableResult
    public func renameConnection(_ id: K8sConnectionID, to name: String) async throws -> K8sConnection {
        try await database.renameConnection(id, to: name)
    }

    public func deleteConnection(_ id: K8sConnectionID) async throws {
        let connection = try await database.deleteConnection(id)
        try await secrets.removeValue(account: connection.account)
    }

    private func metadata(_ preview: KubeconfigPreview) -> KubeconfigMetadata {
        KubeconfigMetadata(context: preview.context, server: preview.server, namespace: preview.namespace,
                           certificateExpiresAt: preview.certificateExpiresAt, byteCount: preview.byteCount, importedAt: Date())
    }
}
