import Foundation
import GRDB

/// App 的数据库入口。打开时执行全部迁移；读写都经由这里的事务方法。
///
/// - 正式运行使用 `DatabasePool`（WAL 模式），界面读取不阻塞调度写入；
/// - 测试使用内存中的 `DatabaseQueue`。
public final class AppDatabase: Sendable {
    /// 直接访问底层连接。仅供测试和迁移检查使用，业务代码应调用仓储方法。
    public let writer: any DatabaseWriter

    /// 用已打开的连接创建，并迁移到最新版本。
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    /// 打开（或创建）磁盘上的数据库文件。所在目录不存在时自动创建。
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: makeConfiguration())
        return try AppDatabase(pool)
    }

    /// 内存数据库，用于测试和预览。
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // 调度写入与界面读取并发时，等待而不是立即报 SQLITE_BUSY。
        configuration.busyMode = .timeout(5)
        return configuration
    }
}
