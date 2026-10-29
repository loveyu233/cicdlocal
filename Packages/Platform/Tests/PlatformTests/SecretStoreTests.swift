import Foundation
import Testing
@testable import Platform

/// 存储行为的共同测试，内存实现和钥匙串实现都要通过。
func exerciseSecretStore(_ store: some SecretStore) async throws {
    try await store.setValue(Data("test".utf8), account: "k8s/a", label: "测试")
    try await store.setValue(Data("prod".utf8), account: "k8s/b", label: "正式")
    #expect(try await store.value(account: "k8s/a") == Data("test".utf8))
    #expect(try await store.value(account: "k8s/b") == Data("prod".utf8))

    // 覆盖写入。
    try await store.setValue(Data("test-2".utf8), account: "k8s/a", label: "测试")
    #expect(try await store.value(account: "k8s/a") == Data("test-2".utf8))

    try await store.removeValue(account: "k8s/a")
    #expect(try await store.value(account: "k8s/a") == nil)
    #expect(try await store.value(account: "k8s/b") == Data("prod".utf8))

    // 删除不存在的条目不报错。
    try await store.removeValue(account: "k8s/a")
    try await store.removeValue(account: "k8s/b")
    #expect(try await store.value(account: "k8s/b") == nil)
}

@Suite("钥匙串")
struct SecretStoreTests {
    @Test("内存实现")
    func inMemory() async throws {
        try await exerciseSecretStore(InMemorySecretStore())
    }

    /// 会写入当前用户的登录钥匙串（独立的 service，结束时删除），默认不运行。
    /// 运行方式：`LOCALCICD_KEYCHAIN_TESTS=1 scripts/test-packages.sh Platform`
    @Test("登录钥匙串（文件钥匙串）",
          .enabled(if: ProcessInfo.processInfo.environment["LOCALCICD_KEYCHAIN_TESTS"] == "1"))
    func fileKeychain() async throws {
        let store = KeychainSecretStore(
            service: "io.github.loveyu233.cicdlocal.tests.\(UUID().uuidString)", mode: .fileBased)
        try await exerciseSecretStore(store)
    }

    @Test("未签名的进程无法使用数据保护钥匙串，错误要可读")
    func dataProtectionNeedsEntitlement() async throws {
        let store = KeychainSecretStore(
            service: "io.github.loveyu233.cicdlocal.tests.\(UUID().uuidString)", mode: .dataProtection)
        do {
            try await store.setValue(Data("x".utf8), account: "probe", label: "probe")
            // 如果在带签名的环境中运行成功了，清理掉。
            try await store.removeValue(account: "probe")
        } catch let error as SecretStoreError {
            guard case .keychain(_, let status, _) = error else {
                Issue.record("意外错误：\(error)")
                return
            }
            #expect(status == -34018) // errSecMissingEntitlement
            #expect(error.description.contains("钥匙串"))
        }
    }
}
