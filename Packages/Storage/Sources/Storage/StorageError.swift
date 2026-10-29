import Models

/// 仓储层的业务错误。SQLite 自身的错误（约束冲突等）以 GRDB 的 `DatabaseError` 原样抛出。
public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(entity: String, id: Int64)
    case invalidValue(String)
    case invalidPushEvent
    case duplicateConnectionName(String)
    case invalidConnectionName

    public var description: String {
        switch self {
        case .notFound(let entity, let id):
            "找不到 \(entity) L-\(id)"
        case .invalidValue(let message): message
        case .invalidPushEvent:
            "推送事件标识不能为空，同一事件不能包含重复的目标引用"
        case .duplicateConnectionName(let name):
            "已经有名为「\(name)」的 k8s 连接"
        case .invalidConnectionName:
            "连接名不能为空，最多 64 个字符"
        }
    }
}
