import Foundation

/// 密钥存储：按 account 保存一段数据。数据库里只保存 account，不保存值。
///
/// 实现必须在主线程以外执行（钥匙串调用可能阻塞）。
public protocol SecretStore: Sendable {
    func value(account: String) async throws -> Data?
    /// 新建或覆盖；`label` 是钥匙串访问里显示的名字。
    func setValue(_ value: Data, account: String, label: String) async throws
    /// 条目不存在时不报错。
    func removeValue(account: String) async throws
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// 钥匙串返回的 OSStatus。
    case keychain(operation: String, status: Int32, message: String)

    public var description: String {
        switch self {
        case .keychain(let operation, let status, let message): "钥匙串\(operation)失败（\(status)）：\(message)"
        }
    }
}

/// 内存实现：用于测试和界面预览，不落盘。
public actor InMemorySecretStore: SecretStore {
    private var storage: [String: Data] = [:]

    public init() {}

    public func value(account: String) -> Data? { storage[account] }
    public func setValue(_ value: Data, account: String, label: String) { storage[account] = value }
    public func removeValue(account: String) { storage[account] = nil }
    public var accounts: [String] { storage.keys.sorted() }
}
