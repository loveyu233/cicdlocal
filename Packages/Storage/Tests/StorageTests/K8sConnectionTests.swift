import Foundation
import Models
import Testing
@testable import Storage

@Suite("k8s 连接")
struct K8sConnectionTests {
    @Test("新建、按名字查找、重命名、更新信息、删除")
    func lifecycle() async throws {
        let database = try AppDatabase.inMemory()
        let created = try await database.createConnection(Sample.connection("  测试环境 "))
        #expect(created.name == "测试环境")
        #expect(created.account.hasPrefix("k8s/"))
        #expect(try await database.connection(named: "测试环境 ") == created)
        #expect(try await database.connection(named: "正式环境") == nil)

        let renamed = try await database.renameConnection(created.id, to: "测试集群")
        #expect(renamed.name == "测试集群" && renamed.account == created.account)
        var metadata = Sample.metadata()
        metadata.server = "https://cluster-two.example.invalid:6443"
        try await database.updateConnectionMetadata(created.id, metadata: metadata)
        #expect(try await database.connection(named: "测试集群")?.metadata.server == "https://cluster-two.example.invalid:6443")

        let deleted = try await database.deleteConnection(created.id)
        #expect(deleted.account == created.account)
        #expect(try await database.connections().isEmpty)
    }

    @Test("名字不能重复，也不能为空")
    func names() async throws {
        let database = try AppDatabase.inMemory()
        let test = try await database.createConnection(Sample.connection("测试环境"))
        let prod = try await database.createConnection(Sample.connection("正式环境"))
        await #expect(throws: StorageError.duplicateConnectionName("测试环境")) {
            try await database.createConnection(Sample.connection("测试环境"))
        }
        await #expect(throws: StorageError.duplicateConnectionName("测试环境")) {
            try await database.renameConnection(prod.id, to: "测试环境")
        }
        // 改成自己的名字不算重复。
        _ = try await database.renameConnection(test.id, to: "测试环境")
        await #expect(throws: StorageError.invalidConnectionName) {
            try await database.createConnection(Sample.connection("   "))
        }
        #expect(try await database.connections().map(\.name).sorted() == ["测试环境", "正式环境"].sorted())
    }
}
