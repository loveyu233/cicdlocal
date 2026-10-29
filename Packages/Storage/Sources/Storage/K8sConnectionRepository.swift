import Foundation
import GRDB
import Models

// k8s 连接只在数据库里记名字、钥匙串 account 和非凭据的展示信息；kubeconfig 由调用方写入钥匙串。

extension AppDatabase {
    /// 新建连接。名字按 `K8sConnection.normalizedName` 规范化后不能与已有连接重复。
    public func createConnection(_ connection: K8sConnection) async throws -> K8sConnection {
        guard let name = K8sConnection.normalizedName(connection.name) else { throw StorageError.invalidConnectionName }
        return try await writer.write { db in
            try Self.ensureUnique(db, name: name, except: nil)
            var connection = connection
            connection.name = name
            try connection.insert(db)
            return connection
        }
    }

    @discardableResult
    public func renameConnection(_ id: K8sConnectionID, to newName: String) async throws -> K8sConnection {
        guard let name = K8sConnection.normalizedName(newName) else { throw StorageError.invalidConnectionName }
        return try await writer.write { db in
            var connection = try Self.fetchConnection(db, id)
            try Self.ensureUnique(db, name: name, except: id)
            connection.name = name
            try connection.update(db)
            return connection
        }
    }

    /// 替换 kubeconfig 后更新展示信息。
    public func updateConnectionMetadata(_ id: K8sConnectionID, metadata: KubeconfigMetadata) async throws {
        try await writer.write { db in
            var connection = try Self.fetchConnection(db, id)
            connection.metadata = metadata
            try connection.update(db)
        }
    }

    /// 删除记录，返回被删除的连接，调用方据此清理钥匙串。
    @discardableResult
    public func deleteConnection(_ id: K8sConnectionID) async throws -> K8sConnection {
        try await writer.write { db in
            let connection = try Self.fetchConnection(db, id)
            try connection.delete(db)
            return connection
        }
    }

    public func connections() async throws -> [K8sConnection] {
        try await writer.read { db in try Self.connectionsRequest.fetchAll(db) }
    }

    /// 按配置里写的名字查找，前后空白不计。
    public func connection(named name: String) async throws -> K8sConnection? {
        guard let name = K8sConnection.normalizedName(name) else { return nil }
        return try await writer.read { db in
            try K8sConnection.filter(Column("name") == name).fetchOne(db)
        }
    }

    static var connectionsRequest: QueryInterfaceRequest<K8sConnection> {
        K8sConnection.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id"))
    }

    private static func fetchConnection(_ db: Database, _ id: K8sConnectionID) throws -> K8sConnection {
        guard let connection = try K8sConnection.fetchOne(db, key: id) else {
            throw StorageError.notFound(entity: "k8s 连接", id: id.rawValue)
        }
        return connection
    }

    private static func ensureUnique(_ db: Database, name: String, except id: K8sConnectionID?) throws {
        var request = K8sConnection.filter(Column("name") == name)
        if let id { request = request.filter(Column("id") != id) }
        if try request.fetchCount(db) > 0 { throw StorageError.duplicateConnectionName(name) }
    }
}
