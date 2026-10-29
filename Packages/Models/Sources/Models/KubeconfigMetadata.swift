import Foundation

/// 导入时提取的非凭据信息，用于界面展示；不保存源文件路径、证书正文、用户凭据或 exec 参数。
public struct KubeconfigMetadata: Codable, Hashable, Sendable {
    public var context: String
    public var server: String
    public var namespace: String
    public var certificateExpiresAt: Date?
    /// 展平后的配置大小。
    public var byteCount: Int
    public var importedAt: Date

    public init(context: String, server: String, namespace: String, certificateExpiresAt: Date?,
                byteCount: Int, importedAt: Date) {
        self.context = context
        self.server = server
        self.namespace = namespace
        self.certificateExpiresAt = certificateExpiresAt
        self.byteCount = byteCount
        self.importedAt = importedAt
    }
}
