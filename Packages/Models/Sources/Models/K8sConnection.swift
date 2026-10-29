import Foundation

/// 在 App 里导入并命名的 k8s 连接，例如「测试环境」「正式环境」。
///
/// `.local.cicd.yml` 的 `deploy[].k8s` 按名字引用它。kubeconfig 本身只在钥匙串里，这里只保存钥匙串 account。
public struct K8sConnection: Identifiable, Hashable, Sendable, Codable {
    public var id: K8sConnectionID
    public var name: String
    /// 钥匙串条目的 account，形如 `k8s/<UUID>`；改名不影响它。
    public var account: String
    public var metadata: KubeconfigMetadata
    public var createdAt: Date

    public init(id: K8sConnectionID, name: String, account: String, metadata: KubeconfigMetadata, createdAt: Date) {
        self.id = id
        self.name = name
        self.account = account
        self.metadata = metadata
        self.createdAt = createdAt
    }

    /// 新连接使用的钥匙串 account。
    public static func newAccount() -> String { "k8s/\(UUID().uuidString)" }

    /// 连接名：去掉首尾空白后 1～64 个字符，不含控制字符。与配置文件里的 `k8s:` 规则一致。
    public static func normalizedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return value
    }
}
