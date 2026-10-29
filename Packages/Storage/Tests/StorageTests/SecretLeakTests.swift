import Foundation
import GRDB
import Models
import Testing
@testable import Storage

@Suite("数据库中没有 kubeconfig 明文")
struct SecretLeakTests {
    @Test("完整走一遍连接的增删改查后，数据库文件（含 -wal、-shm）中搜不到 kubeconfig")
    func noPlaintextOnDisk() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "app.sqlite")
        let secret = "LOCALCICD-SENTINEL-\(UUID().uuidString)"
        let name = "正式环境-\(UUID().uuidString.prefix(8))"
        // 代替钥匙串。Storage 没有任何接受 kubeconfig 的接口，内容只能放在这里。
        var keychain: [String: String] = [:]

        let database = try AppDatabase.open(at: url)
        var connection = try await database.createConnection(Sample.connection(name))
        keychain[connection.account] = secret
        connection = try await database.renameConnection(connection.id, to: name + "-新")
        try await database.updateConnectionMetadata(connection.id, metadata: Sample.metadata())
        let other = try await database.createConnection(Sample.connection("测试环境"))
        keychain[other.account] = secret
        try await database.deleteConnection(other.id)
        #expect(keychain.count == 2)

        // 不做 checkpoint：-wal 中的内容也要检查。
        let files = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent == "app.sqlite-wal" })
        var foundName = false
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(file.lastPathComponent) 中出现了 kubeconfig 明文")
            foundName = foundName || bytes.range(of: Data(name.utf8)) != nil
        }
        // 对照：连接名确实写进了文件，说明上面的搜索是有效的。
        #expect(foundName)
    }
}
