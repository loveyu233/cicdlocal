import Foundation
import Security

/// 基于钥匙串“通用密码”的密钥存储。actor 保证调用不在主线程执行。
///
/// - `dataProtection`：数据保护钥匙串，不会弹出访问授权，但要求进程带签名和应用标识权限；
///   未签名的进程会得到 -34018。正式 App 使用此模式。
/// - `fileBased`：传统的登录钥匙串，不需要权限，签名变化后可能弹出授权提示。
public actor KeychainSecretStore: SecretStore {
    public enum Mode: Sendable {
        case dataProtection
        case fileBased
    }

    public nonisolated let service: String
    public nonisolated let mode: Mode

    public init(service: String = AppPaths.bundleIdentifier + ".k8s", mode: Mode = .dataProtection) {
        self.service = service
        self.mode = mode
    }

    public func value(account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "读取")
        return result as? Data
    }

    public func setValue(_ value: Data, account: String, label: String) throws {
        var query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: value, kSecAttrLabel as String: label]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = value
            query[kSecAttrLabel as String] = label
            // 只在本机、解锁后可用，不随 iCloud 同步。
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil), "写入")
        } else {
            try check(status, "更新")
        }
    }

    public func removeValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "删除")
    }

    // MARK: 私有

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if mode == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        throw SecretStoreError.keychain(operation: operation, status: status, message: message)
    }
}
