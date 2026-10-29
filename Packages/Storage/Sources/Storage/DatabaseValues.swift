import Foundation
import GRDB
import Models

// Models 不依赖 GRDB，列值转换集中在这里补上。
// `@retroactive`：Models 永远不会自己声明这些一致性，不存在重复实现的风险。

extension LocalID: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalID? {
        Int64.fromDatabaseValue(dbValue).map(LocalID.init(rawValue:))
    }
}

/// 读出的 SHA 不合法时返回 nil，GRDB 会报解码错误，而不是带着坏数据继续运行。
extension CommitSHA: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}

extension HookMode: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}
extension RefUpdateConfirmation: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}
extension ConfirmationLayer: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}
extension RunStatus: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}
extension StageKind: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}
extension StageStatus: @retroactive SQLExpressible, @retroactive StatementBinding, @retroactive DatabaseValueConvertible {}

// MARK: JSON 列

/// 小结构以 JSON 文本存储。键排序，保证同样的值写出同样的文本。
enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(text.utf8))
    }
}
